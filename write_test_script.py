import base64, sys
# Read base64 from stdin and decode to file
b = sys.stdin.read().strip()
open(r"C:\Users\s7514\Documents\Cline\Hooks\Test-TaskCompleteHook.ps1","wb").write(base64.b64decode(b))
print("Script written successfully")
