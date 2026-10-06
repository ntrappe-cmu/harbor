import Foundation
import Darwin
import HarborCore

struct ContainerRuntime: Sendable {
    let executable: String
    let runner = CommandRunner()
    static func discover() -> String? {
        ["/usr/local/bin/container", "/opt/homebrew/bin/container"].first {
            FileManager.default.isExecutableFile(atPath: $0)
        }
    }
    func checked(_ args: [String], input: String? = nil, timeout: TimeInterval = 60,
                 output: (@Sendable (String) -> Void)? = nil, interruptOnCancel: Bool = false) async throws -> String {
        let result = try await runner.run(executable, args, input: input, timeout: timeout, onOutput: output, cancellationSignal: interruptOnCancel ? SIGINT : SIGTERM)
        guard result.code == 0 else {
            throw WorkspaceError.invalid(String(result.output.suffix(3000)).isEmpty ? "The workspace service did not complete this operation." : String(result.output.suffix(3000)))
        }
        return result.output
    }
    func health(timeout: TimeInterval = 60) async throws -> String {
        let version = try await checked(["--version"], timeout: timeout)
        guard version.contains("container CLI version 1.5.") else {
            throw WorkspaceError.invalid("This Harbor build requires Apple container 1.5.x. Install the supported runtime before preparing workspace tools.")
        }
        return version
    }
    func startService() async throws { _ = try await checked(["system", "start"], timeout: 180) }
    func prepare(at root: URL, output: @escaping @Sendable (String) -> Void) async throws {
        _ = try await health()
        try Task.checkCancellation()
        let context = root.appendingPathComponent("Runtime", isDirectory: true)
        try FileManager.default.createDirectory(at: context, withIntermediateDirectories: true)
        try Self.containerfile.write(to: context.appendingPathComponent("Dockerfile"), atomically: true, encoding: .utf8)
        try Self.previewServer.write(to: context.appendingPathComponent("preview.cjs"), atomically: true, encoding: .utf8)
        _ = try await checked(["build", "--cpus", "2", "--memory", "2G", "-t", Self.image, context.path], timeout: 900, output: output, interruptOnCancel: true)
    }
    func create(_ workspace: Workspace, project: URL, id: String) async throws {
        let arguments = try RuntimePolicy.runArguments(workspace, project: project, id: id, image: Self.image)
        _ = try await checked(arguments, timeout: 180)
    }
    static let image = "harbor-agents:v3"
    func stats(_ id: String) async throws -> ResourceSample {
        try ResourceSample.parse(await checked(["stats", id, "--format", "json", "--no-stream"], timeout: 12), id: id)
    }
    func execute(_ assistant: Assistant, in id: String, prompt: String, key: String, token: UUID = UUID(), session: String? = nil,
                 output: @escaping @Sendable (String) -> Void) async throws -> String {
        // Credentials are passed over stdin, not argv, host environment, or workspace files.
        // They remain accessible to trusted code inside this VM. No secret-vault claim.
        let variable = assistant == .claude ? "ANTHROPIC_API_KEY" : "CODEX_API_KEY"
        let script = "IFS= read -r \(variable); export \(variable); exec \"$@\""
        return try await checked(["exec", "-i", "--workdir", "/workspace", id, "node", "-e", Self.agentLauncher, token.uuidString, script] + assistant.arguments(resuming: session),
                                 input: key + "\n" + prompt + "\n", timeout: 86_400, output: output)
    }
    func cancelAgent(in id: String, token: UUID) async throws {
        _ = try await checked(["exec", id, "node", "-e", Self.agentStopper, token.uuidString], timeout: 15)
    }
    static let processScanner = """
    function stat(pid){const s=fs.readFileSync('/proc/'+pid+'/stat','utf8');return s.slice(s.lastIndexOf(') ')+2).split(' ')}
    function members(){return fs.readdirSync('/proc').filter(x=>/^\\d+$/.test(x)).flatMap(x=>{try{const s=stat(x);const env=fs.readFileSync('/proc/'+x+'/environ','utf8').split('\\0');return s[0]!=='Z'&&env.includes('HARBOR_TASK_ID='+token)?[{pid:Number(x),start:s[19]}]:[]}catch{return []}})}
    function signal(job,kind){try{if(stat(job.pid)[19]===job.start)process.kill(job.pid,kind)}catch(e){if(!['ESRCH','ENOENT'].includes(e.code))throw e}}
    async function drain(){members().forEach(j=>signal(j,'SIGTERM'));for(let n=0;n<30&&members().length;n++)await new Promise(r=>setTimeout(r,100));members().forEach(j=>signal(j,'SIGKILL'));for(let n=0;n<20&&members().length;n++)await new Promise(r=>setTimeout(r,100));if(members().length)throw Error('Task stop not confirmed')}
    """
    static let agentLauncher = """
    const fs=require('fs'), cp=require('child_process');
    const [token,script,...args]=process.argv.slice(1), file='/tmp/harbor-agent-'+token+'.json';
    \(processScanner)
    const child=cp.spawn('sh',['-c',script,'harbor-agent',...args],{detached:true,stdio:'inherit',env:{...process.env,HARBOR_TASK_ID:token}});
    child.on('error',()=>process.exit(1));
    child.on('spawn',()=>{
      try {fs.writeFileSync(file,JSON.stringify({token,pid:child.pid,start:stat(child.pid)[19]}),{flag:'wx'})}
      catch {try{process.kill(-child.pid,'SIGKILL')}catch{};process.exit(1)}
    });
    child.on('exit',async(code)=>{try{await drain();fs.writeFileSync(file+'.done','stopped');try{fs.unlinkSync(file)}catch{};process.exit(code===null?130:code)}catch(e){console.error(e.message);process.exit(1)}});
    """
    static let agentStopper = """
    const fs=require('fs'), token=process.argv[1], file='/tmp/harbor-agent-'+token+'.json';
    \(processScanner)
    (async()=>{
      for(let n=0;n<20&&!fs.existsSync(file);n++) await new Promise(r=>setTimeout(r,100));
      if(!fs.existsSync(file)) {if(fs.existsSync(file+'.done')&&!members().length)return;throw Error('Task identity unavailable; retry Stop Task')}
      const job=JSON.parse(fs.readFileSync(file,'utf8'));
      if(job.token!==token||!Number.isInteger(job.pid)||job.pid<=1)throw Error('Task identity mismatch');
      try {if(stat(job.pid)[19]!==job.start)throw Error('Task process identity changed')}catch(e){if(e.code!=='ENOENT')throw e}
      await drain();
    })().catch(e=>{console.error(e.message);process.exit(1)});
    """
    func stop(_ id: String) async throws {
        let result = try await runner.run(executable, ["stop", "--time", "5", id], timeout: 30)
        if result.code != 0 {
            // A deadline or an earlier stop may already have stopped/deleted this VM.
            let list = try await checked(["list", "--format", "json"])
            if try RuntimePolicy.containerIDs(list).contains(id) { throw WorkspaceError.invalid(result.output) }
        }
    }
    func remove(_ id: String) async throws {
        let result = try await runner.run(executable, ["delete", id], timeout: 30)
        if result.code != 0 {
            let list = try await checked(["list", "--all", "--format", "json"])
            if try RuntimePolicy.containerIDs(list).contains(id) { throw WorkspaceError.invalid(result.output) }
        }
    }
    func extend(_ id: String, seconds: Int) async throws {
        _ = try await checked(["exec", id, "node", "-e", "const fs=require('fs'); const p='/tmp/harbor-deadline'; fs.writeFileSync(p,String(Number(fs.readFileSync(p,'utf8'))+Number(process.argv[1])*1000));", String(seconds)])
    }
    func inspect(_ id: String) async throws -> String { try await checked(["inspect", id]) }
    static let containerfile = """
    FROM node:22-bookworm-slim
    RUN apt-get update && apt-get install -y --no-install-recommends git ca-certificates && rm -rf /var/lib/apt/lists/*
    RUN npm install -g @anthropic-ai/claude-code@2.1.289 @openai/codex@0.160.0
    COPY preview.cjs /opt/harbor/preview.cjs
    ENV HOME=/home/node
    USER node
    WORKDIR /workspace
    EXPOSE 4173
    """
    static let previewServer = """
    const http = require('http'), fs = require('fs'), path = require('path');
    const root = '/workspace';
    const deadlineFile = '/tmp/harbor-deadline';
    const deadline = Number(process.env.HARBOR_DEADLINE_MS);
    if (!Number.isFinite(deadline) || deadline <= Date.now()) process.exit(1);
    fs.writeFileSync(deadlineFile,String(deadline));
    setInterval(() => {
      try { if (Date.now() >= Number(fs.readFileSync(deadlineFile,'utf8'))) process.exit(0); }
      catch { process.exit(1); }
    },1000);
    const types = {'.html':'text/html', '.css':'text/css', '.js':'text/javascript', '.svg':'image/svg+xml', '.png':'image/png', '.jpg':'image/jpeg'};
    http.createServer((req,res) => {
      res.setHeader('X-Harbor-Preview',process.env.HARBOR_RUN_ID || 'unknown');
      try {
        const name = decodeURIComponent(new URL(req.url,'http://localhost').pathname);
        const candidate = path.resolve(root, '.' + (name === '/' ? '/index.html' : name));
        const real = fs.realpathSync(candidate);
        if (!real.startsWith(root + '/') || real.split('/').some(x => x.startsWith('.'))) {res.writeHead(403); return res.end('Not available');}
        const stat = fs.statSync(real); if (!stat.isFile()) throw Error('Not a file');
        res.setHeader('Content-Type',types[path.extname(real)] || 'application/octet-stream');
        res.setHeader('Cache-Control','no-store'); fs.createReadStream(real).pipe(res);
      } catch {res.writeHead(404); res.end('This preview serves index.html and static files. Export framework projects to run them separately.');}
    }).listen(4173,'0.0.0.0');
    """
}
