import terminex

let session = newTerminalSession(columns = 80, rows = 24)
session.processOutput("first line\r\n")
var displayed = session.copyScreen()
session.processOutput("more output")
displayed.applySnapshot(session.captureScreenUpdate(displayed.info))
echo displayed.plainText()
