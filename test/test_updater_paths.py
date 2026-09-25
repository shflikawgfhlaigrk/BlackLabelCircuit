"""Regression: archive filenames remain data in the actual update installer."""
from pathlib import Path
import os,subprocess,tempfile,textwrap,unittest
ROOT=Path(__file__).resolve().parents[1]
NAMES=['ordinary.app','Space and unicode Ω.app','renamed$(touch sentinel).app','renamed`touch sentinel`.app','quote";touch sentinel;#.app',"single'quote.app",'line\nbreak.app']

def extract(source):
    start=source.index('let script = """',source.index('static func performSwapAndRelaunch'))
    return textwrap.dedent(source[start+len('let script = """'):source.index('"""',start+len('let script = """'))]).strip()+'\n'


def exercise(script,name,legacy=False,missing=False):
    with tempfile.TemporaryDirectory(prefix='installer-path-proof-') as td:
        work=Path(td);installed=work/'Installed $(touch installed-sentinel).app';staged=work/name;backup=work/'Backup.app'
        installed.mkdir();(installed/'old-marker').write_text('old')
        if not missing:staged.mkdir();(staged/'new-marker').write_text('new')
        stubs=work/'bin';stubs.mkdir()
        for cmd in ('open','xattr'):
            stub=stubs/cmd;stub.write_text('#!/bin/sh\nexit 0\n');stub.chmod(0o700)
        helper=work/'helper.sh'
        if legacy:
            for key,value in [('pid','99999999'),('installed',str(installed)),('staged',str(staged)),('backup',str(backup))]:script=script.replace('\\('+key+')',value)
            args=[]
        else:
            assert '\\(' not in script
            args=['99999999',str(installed),str(staged),str(backup)]
        helper.write_text(script)
        result=subprocess.run(['/bin/sh',str(helper),*args],cwd=work,env={**os.environ,'PATH':str(stubs)+':/usr/bin:/bin'},capture_output=True,text=True,timeout=10)
        injected=(work/'sentinel').exists() or (work/'installed-sentinel').exists()
        if legacy:
            assert injected,'baseline command substitution was not reproduced'
        else:
            assert not injected, (name,result.stderr)
            if missing:
                assert result.returncode!=0 and (installed/'old-marker').read_text()=='old'
            else:
                assert result.returncode==0,(name,result.stderr)
                assert (installed/'new-marker').read_text()=='new'
                assert not backup.exists() and not staged.exists()
        return {'exit':result.returncode,'command_injection':injected,'rollback':missing}

class UpdaterPathTests(unittest.TestCase):
    def test_filename_data_and_rollback(self):
        source=(ROOT/'macos/CircuitUpdater.swift').read_text()
        self.assertIn('p.arguments = [helper.path, String(pid), installed, staged, backup]',source)
        script=extract(source)
        for name in NAMES:
            with self.subTest(name=name):exercise(script,name)
        exercise(script,'missing.app',missing=True)

if __name__=='__main__':unittest.main()
