#!/usr/bin/env python3
"""Execute unchanged setup scripts with isolated filesystems and inert devices.

Requires Linux, bubblewrap, BusyBox, and Python 3. No network or real service,
package-manager, device, mount, or formatting operation is available in a run.
This verifies shell behavior; it does not certify physical radio/RF operation.
"""
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile

REPO = Path(__file__).resolve().parents[1]
MOCK = r'''#!/usr/bin/python3
import hashlib,json,os,signal,sys
from pathlib import Path
n=Path(sys.argv[0]).name;a=sys.argv[1:];s=Path('/state')
row={'command':n,'args':a}
if n in ('crow','crow-watchdog'):
 p=Path('/usr/local/crow/crow.conf')
 row['config_sha256']=hashlib.sha256(p.read_bytes()).hexdigest() if p.exists() else None
with (s/'calls.jsonl').open('a') as f:f.write(json.dumps(row)+'\n')
if n in ('apk','opkg'):
 p=s/'installed.json';installed=json.loads(p.read_text())
 if a[:2]==['info','-e']:sys.exit(0 if a[2] in installed else 1)
 if a==['list-installed']:
  print('\n'.join(x+' - 1' for x in installed));sys.exit(0)
 if a and a[0] in ('add','install'):
  if (s/'fail-package').exists() and (s/'fail-package').read_text()==a[1]:sys.exit(1)
  if a[1] not in installed:installed.append(a[1]);p.write_text(json.dumps(installed))
elif n=='ps':
 if (s/'crow-running').exists():print('123 root 4096 S /usr/bin/ucode -L /usr/local/crow /usr/local/crow/crow.uc')
elif n=='date':print('1000')
elif n=='block':
 kind=(s/'filesystem').read_text() if (s/'filesystem').exists() else 'ext4'
 print('/dev/sda1: UUID="fixture" LABEL="CROWDATA" TYPE="'+kind+'"')
elif n=='socat':
 count=s/'socat-count';number=int(count.read_text())+1 if count.exists() else 1;count.write_text(str(number))
 if number==1:
  Path('/state/dev/ttyACM0').rename('/state/dev/ttyACM7')
 else:os.kill(os.getppid(),signal.SIGTERM)
sys.exit(0)
'''


class Sandbox:
    def __init__(self, package_manager='apk'):
        self.temp = tempfile.TemporaryDirectory(prefix='crow-setup-sandbox-')
        self.root = Path(self.temp.name)
        for name in ('bin','sbin','etc/init.d','etc/rc.d','etc/local/mesh-firewall',
                     'local/crow/platforms/aredn','tmp','sys','mnt','state','overlay'):
            (self.root/name).mkdir(parents=True, exist_ok=True)
        shutil.copy2(shutil.which('busybox'), self.root/'bin/busybox')
        for name in ('cat','cp','rm','mkdir','chmod','ls','grep','sed','awk','tr',
                     'find','dirname','basename','readlink','df','touch','kill','printf','env'):
            (self.root/'bin'/name).symlink_to('busybox')
        # Use an external-command-resolving shell; BusyBox standalone-shell
        # builds can bypass PATH mocks for applets such as ps and date.
        shutil.copy2(Path('/bin/sh').resolve(), self.root/'bin/sh')
        shutil.copy2(Path(shutil.which('python3')).resolve(), self.root/'bin/python3')
        for name in ('logger','sleep','ps','date',package_manager,'socat','mkfs.ext4','ucode'):
            self.write('bin/'+name, MOCK, 0o755)
        for name in ('modprobe','block','uci','mount'):
            self.write('sbin/'+name, MOCK, 0o755)
        for name in ('crow','crow-watchdog'):
            self.write('etc/init.d/'+name, MOCK, 0o755)
        self.write('etc/local/mesh-firewall/21-crow', MOCK, 0o755)
        self.write('state/installed.json', json.dumps(['kmod-usb-storage','kmod-scsi-core','block-mount','kmod-fs-ext4']))
        for name in ('crow-migrate-raven.sh','usb-setup.sh','crow-watchdog.sh'):
            shutil.copy2(REPO/'platforms/aredn'/name, self.root/'local/crow/platforms/aredn'/name)

    def write(self, name, body, mode=0o600):
        p=self.root/name;p.parent.mkdir(parents=True,exist_ok=True);p.write_text(body);p.chmod(mode)

    def calls(self, name=None):
        p=self.root/'state/calls.jsonl'
        rows=[json.loads(x) for x in p.read_text().splitlines()] if p.exists() else []
        return [r for r in rows if name is None or r['command']==name]

    def run(self, relative, args=(), env=None, code=None):
        command=['bwrap','--tmpfs','/','--ro-bind','/usr','/usr',
                 '--symlink','usr/bin','/bin','--symlink','usr/sbin','/sbin',
                 '--symlink','usr/lib','/lib','--symlink','usr/lib64','/lib64',
                 '--unshare-net','--unshare-pid',
                 '--die-with-parent','--new-session','--proc','/proc','--dev','/dev']
        for local,target in [('bin','/usr/bin'),('sbin','/usr/sbin'),('etc','/etc'),
                             ('local','/usr/local'),('tmp','/tmp'),('sys','/sys'),
                             ('mnt','/mnt'),('state','/state'),('overlay','/overlay')]:
            command+=['--bind',str(self.root/local),target]
        command+=['--ro-bind',str(REPO),'/src','--setenv','PATH','/usr/bin:/usr/sbin','--chdir','/state']
        for key,value in (env or {}).items():command+=['--setenv',key,str(value)]
        command+=['--','/bin/sh']
        command+=['-c',code] if code is not None else ['/src/'+relative,*args]
        result=subprocess.run(command,text=True,capture_output=True,timeout=15)
        return result

    def drive(self, filesystem='ext4'):
        self.write('sys/bus/usb/devices/usb1/product','fixture controller')
        self.write('sys/block/sda/removable','1')
        self.write('sys/block/sda/size','2048000')
        self.write('sys/block/sda/device/model','fixture storage')
        (self.root/'sys/block/sda/sda1').mkdir()
        self.write('state/filesystem',filesystem)

    def close(self):self.temp.cleanup()


def main():
    missing=[x for x in ('bwrap','busybox','python3') if not shutil.which(x)]
    if missing:
        print('SKIP: backend setup execution tests require '+', '.join(missing));return 0
    probe=subprocess.run(['bwrap','--ro-bind','/','/','--unshare-net','--die-with-parent','--','/bin/true'],capture_output=True,text=True)
    if probe.returncode:
        print('SKIP: bubblewrap isolation is unavailable: '+probe.stderr.strip());return 0
    passed=0

    def check(label, fn):
        nonlocal passed
        box=Sandbox()
        try:fn(box)
        finally:box.close()
        passed+=1;print('ok   - '+label,flush=True)

    def expect(result, status=0):
        assert result.returncode==status,(result.returncode,result.stdout,result.stderr)

    def fresh(box):
        box.write('local/crow/crow.conf','{"channels":[]}\n')
        box.write('etc/cron.daily/crow-update','obsolete')
        expect(box.run('platforms/aredn/postinstall'))
        assert (box.root/'local/crow/data').is_dir()
        assert (box.root/'tmp/apps/crow/images').is_dir()
        assert not (box.root/'etc/cron.daily/crow-update').exists()
        assert [(r['command'],r['args']) for r in box.calls()]==[
            ('crow',['enable']),('crow',['start']),('crow-watchdog',['enable']),
            ('crow-watchdog',['start']),('21-crow',[])]
        assert not (box.root/'etc/crow.conf.override').exists()
    check('fresh APK install creates state, starts services, and does not invent a saved override',fresh)

    def upgrade(box):
        original='{"meshcore":{"backend":"tcp"},"operator":"fixture"}\n'
        box.write('local/crow/crow.conf',original)
        expect(box.run('platforms/aredn/preupgrade'))
        box.write('local/crow/crow.conf','{"factory":true}\n')
        expect(box.run('platforms/aredn/postupgrade'))
        assert (box.root/'local/crow/crow.conf').read_text()==original
        assert not (box.root/'tmp/crow.conf.pre-upgrade').exists()
        assert [r['args'] for r in box.calls()]==[['restart'],['restart']]
        assert all(r['config_sha256']==hashlib.sha256(original.encode()).hexdigest() for r in box.calls())
    check('APK upgrade restores operator configuration before service restarts',upgrade)

    def remove(box):
        expect(box.run('platforms/aredn/prerm'))
        assert [(r['command'],r['args']) for r in box.calls()]==[
            ('crow-watchdog',['stop']),('crow-watchdog',['disable']),('crow',['stop']),('crow',['disable'])]
    check('removal stops watchdog before Crow',remove)

    def usb(box, manager='apk', failure=None, filesystem='ext4', mode='assimilate', missing=False):
        if manager=='opkg':
            (box.root/'bin/apk').unlink();box.write('bin/opkg',MOCK,0o755)
        box.drive(filesystem)
        if missing:box.write('state/installed.json','[]')
        if failure:
            box.write('state/installed.json','[]');box.write('state/fail-package',failure)
        r=box.run('platforms/aredn/usb-setup.sh',[mode])
        expect(r,11 if failure else 14 if filesystem=='unknown' else 0)
        status=(box.root/'tmp/crow-storage-assimilate.status').read_text().strip()
        assert status==('package-install-failed' if failure else 'unsupported-filesystem' if filesystem=='unknown' else 'ready')
        assert not box.calls('mkfs.ext4')
        if not failure and not missing:
            assert not [c for c in box.calls(manager) if c['args'][0] in ('update','add','install')]
        if missing and not failure:
            calls=box.calls(manager)
            assert sum(c['args']==['update'] for c in calls)==1,calls
            assert [c['args'][1] for c in calls if c['args'][0] in ('add','install')]==[
                'kmod-usb-storage','kmod-scsi-core','block-mount','kmod-fs-ext4'],calls
        assert not list((box.root/'sys').rglob('unbind'))
    check('APK USB assimilation uses existing packages and never formats or resets serial',lambda b:usb(b))
    check('opkg USB assimilation executes the legacy package path',lambda b:usb(b,manager='opkg'))
    check('missing storage dependencies are installed once before ready status',lambda b:usb(b,missing=True))
    check('USB package-install failure returns actionable failure status',lambda b:usb(b,failure='kmod-usb-storage'))
    check('unknown existing filesystem is rejected without formatting',lambda b:usb(b,filesystem='unknown'))

    def invalid(box):
        expect(box.run('platforms/aredn/usb-setup.sh',['not-a-mode']),2)
        assert box.calls()==[]
    check('invalid USB setup mode has no package or device effects',invalid)

    def watchdog(box, enabled=True, running=True, heartbeat='999', restart=False):
        if enabled:box.write('etc/rc.d/S99crow','enabled')
        if running:box.write('state/crow-running','yes')
        if heartbeat is not None:box.write('tmp/crow-heartbeat',heartbeat)
        expect(box.run('platforms/aredn/crow-watchdog.sh',['--once']))
        assert len(box.calls('crow'))==(1 if restart else 0),box.calls()
        if restart:assert box.calls('crow')[0]['args']==['restart']
    for label,values in [
        ('healthy process is not restarted',{}),
        ('disabled service stays stopped',{'enabled':False,'running':False}),
        ('missing process is restarted',{'running':False,'restart':True}),
        ('stale heartbeat is restarted',{'heartbeat':'100','restart':True}),
        ('invalid heartbeat is restarted',{'heartbeat':'broken','restart':True}),
        ('backward clock is not treated as stale',{'heartbeat':'1100'}),
    ]:check('watchdog: '+label,lambda b,v=values:watchdog(b,**v))

    def bridge(box):
        box.write('state/dev/ttyACM0','')
        result=box.run('tools/crow-serial-bridge',env={
            'CROW_SERIAL_DEV_ROOT':'/state/dev','CROW_SERIAL_SYS_TTY_ROOT':'/state/sys',
            'CROW_SERIAL_TEST_MODE':'1','CROW_SERIAL_RETRY_SECONDS':'0'})
        expect(result)
        calls=box.calls('socat')
        assert len(calls)==2,calls
        assert 'FILE:/state/dev/ttyACM0,raw,nonblock,echo=0' in calls[0]['args']
        assert 'FILE:/state/dev/ttyACM7,raw,nonblock,echo=0' in calls[1]['args']
        assert all('TCP-LISTEN:4405,bind=127.0.0.1,reuseaddr' in c['args'] for c in calls)
    check('bridge loop re-resolves a changed ACM number and keeps listener loopback-only',bridge)

    def init(box, name, expected_command, expected_respawn):
        code='''procd_open_instance() { :; }
procd_close_instance() { :; }
procd_set_param() { printf '%s\\n' "$*" >> /state/procd.txt; }
. /src/'''+name+'''
start_service
'''
        expect(box.run(name,code=code))
        lines=(box.root/'state/procd.txt').read_text().splitlines()
        assert 'command '+expected_command in lines,lines
        assert 'respawn '+expected_respawn in lines,lines
        if 'serial-bridge' in name:assert 'env CROW_SERIAL_USB_ID=239a:8029' in lines
    check('Crow procd starts the application entry point with persistent respawn',lambda b:init(b,
        'platforms/aredn/crow.init','/usr/bin/ucode -L /usr/local/crow /usr/local/crow/crow.uc','3600 5 0'))
    check('watchdog procd starts the monitoring loop with persistent respawn',lambda b:init(b,
        'platforms/aredn/crow-watchdog.init','/usr/local/crow/platforms/aredn/crow-watchdog.sh --loop','3600 10 0'))
    check('USB bridge init applies the intended device identity',lambda b:init(b,
        'tools/bb5-crow-serial-bridge.init','/usr/local/crow/crow-serial-bridge','3600 5 5'))

    def runner(box):
        expect(box.run('platforms/aredn/crow-runner.sh',['--fixture-arg']))
        calls=box.calls('ucode')
        assert len(calls)==1,calls
        assert calls[0]['args']==['-L','/usr/local/crow','/usr/local/crow/crow.uc','--fixture-arg'],calls
    check('runner starts the same application as procd and forwards arguments',runner)
    print(f'\n{passed} isolated backend/setup execution checks passed')
    return 0


if __name__=='__main__':raise SystemExit(main())
