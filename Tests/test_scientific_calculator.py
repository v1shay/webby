#!/usr/bin/env python3
from pathlib import Path
import subprocess, tempfile
source = (Path(__file__).resolve().parent.parent / "WidgetExtras.swift").read_text()
parser = source[source.index("struct ExpressionCalculator {"):source.index("// One bounded last cover")]
with tempfile.TemporaryDirectory(prefix="webby-calculator-") as directory:
    script = Path(directory) / "Check.swift"
    script.write_text("import Foundation\n" + parser + 'let cases: [(String, Double)] = [("9/(2^2+4)",1.125),("2+3*4",14),("-2^2",-4),("2^3^2",512),("2^-2",0.25),("sqrt(81)+pi",9+Double.pi),("2π",2*Double.pi),("2(3+4)",14),("sin(pi/2)",1),("sin(90°)",1),("ln(e)",1),("log(100)",2),("5!",120),("50%",0.5),("ans*2",84),("1e-3+2",2.001),("pow(2,10)",1024),("√(16)+cbrt(27)",7),("log(8,2)",3),("abs(-9)",9)]\nfor (text, expected) in cases { var p = ExpressionCalculator(text, ans:42); guard let v = p.evaluate(), abs(v-expected)<1e-9 else { fatalError("Failed \\(text)") } }\nfor text in ["1/0","sqrt(-1)","2+", "sin()", "171!", "unknown(3)", String(repeating:"(",count:200)+"1"+String(repeating:")",count:200)] { var p=ExpressionCalculator(text); assert(p.evaluate()==nil,text) }\nprint("PASS: 20 scientific/precedence/ans cases and 7 invalid/bounded input cases")\n')
    subprocess.run(["swift", str(script)], check=True)
