"""No-provider runtime smoke: creates only temporary Harbor verification containers."""
import json, pathlib, subprocess, tempfile, time, uuid
cli = '/usr/local/bin/container'
root = pathlib.Path(tempfile.mkdtemp(prefix='harbor-policy-'))
(root / 'original.txt').write_text('original')
ids = []
results = {}
caps = ['NET_RAW','NET_ADMIN','SYS_ADMIN','SYS_PTRACE','SYS_MODULE','SYS_RAWIO','SYS_BOOT','SYS_TIME']

def command(args):
    result = subprocess.run([cli] + args, text=True, capture_output=True, timeout=90)
    if result.returncode:
        raise RuntimeError(result.stderr + result.stdout)
    return result.stdout

try:
    for readonly in [True, False]:
        cid = 'harbor-policy-' + str(uuid.uuid4()).lower()
        ids.append(cid)
        args = ['run','-d','--name',cid,'--cpus','1','--memory','1G','--network','none',
                '--mount',f'type=bind,source={root},target=/workspace' + (',readonly' if readonly else ''),
                '--env',f'HARBOR_DEADLINE_MS={int((time.time()+300)*1000)}','--env',f'HARBOR_RUN_ID={cid}']
        for cap in caps: args += ['--cap-drop',cap]
        command(args + ['harbor-agents:v3','node','/opt/harbor/preview.cjs'])
        js = """const fs=require('fs');
        const status=fs.readFileSync('/proc/self/status','utf8');
        const eff=BigInt('0x'+status.match(/^CapEff:\\s*(\\w+)/m)[1]);
        const bnd=BigInt('0x'+status.match(/^CapBnd:\\s*(\\w+)/m)[1]);
        const bits=[13,12,21,19,16,17,22,25];
        if(bits.some(bit=>((eff|bnd)&(1n<<BigInt(bit)))!==0n))throw Error('Restricted capability remained');
        if(fs.readFileSync('/workspace/original.txt','utf8')!=='original')throw Error('Read failed');
        let write=false;try{fs.writeFileSync('/workspace/new.txt','written');write=true}catch(e){if(!['EROFS','EACCES','EPERM'].includes(e.code))throw e}
        fs.writeFileSync('/tmp/harbor-policy-temp','writable');
        console.log(JSON.stringify({write,capabilitiesRestricted:true,temporaryFilesWritable:true}));"""
        data = json.loads(command(['exec',cid,'node','-e',js]).strip())
        assert data['write'] == (not readonly), data
        results['readonly' if readonly else 'writable'] = data
        command(['stop',cid]); command(['delete',cid]); ids.remove(cid)
    results['hostOriginalPreserved'] = (root/'original.txt').read_text() == 'original'
    assert results['hostOriginalPreserved']
    out = pathlib.Path(__file__).resolve().parents[1] / '.local-data/policy-verification.json'
    out.parent.mkdir(parents=True,exist_ok=True)
    out.write_text(json.dumps(results,indent=2))
    print(json.dumps(results,indent=2))
finally:
    for cid in ids:
        for action in ['stop','delete']:
            subprocess.run([cli,action,cid],capture_output=True,timeout=30)
    import shutil
    shutil.rmtree(root)
