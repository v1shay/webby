from pathlib import Path
import sys,subprocess
root=Path(__file__).resolve().parents[1]
work=Path(sys.argv[1]);work.mkdir(parents=True,exist_ok=True)
source=(root/'BrowserPerformance.swift').read_text()
source=source[source.index('final class BrowserSnapshotWriter:'):]
code='import Foundation\n'+source+'\n'+(root/'Tests/SessionPersistenceBench.swift').read_text()
(work/'SessionPersistenceBench.swift').write_text(code)
subprocess.run(['swiftc','-O','-parse-as-library',str(work/'SessionPersistenceBench.swift'),'-o',str(work/'session-bench')],check=True)
