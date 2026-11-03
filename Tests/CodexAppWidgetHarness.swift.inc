extension CodexAppWidgetView {
    func verifyComposer()->Bool {
        let id = UUID().uuidString
        snapshot.chats = [.init(id:id,title:"Fixture chat",directory:"/fixture",updated:Date())]
        selected = id
        needsLayout=true;layoutSubtreeIfNeeded()
        guard prompt.isEditable,prompt.isSelectable,!prompt.isHidden,
              window?.makeFirstResponder(prompt)==true,let editor=prompt.currentEditor() as? NSTextView else { print("CODEX FIXTURE focus",bounds,prompt.frame,prompt.isEditable,prompt.isSelectable,prompt.isHidden,window?.firstResponder as Any); return false }
        editor.insertText("Explain this code",replacementRange:NSRange(location:NSNotFound,length:0))
        guard editor.string == "Explain this code" else { print("CODEX FIXTURE text",editor.string);return false }
        let point = prompt.convert(NSPoint(x:prompt.bounds.midX,y:prompt.bounds.midY),to:self)
        guard containsControl(point) else { print("CODEX FIXTURE hit",point,prompt.frame); return false }
        selected = nil // Clear the fixture recipient before ending editing can dispatch an action.
        window?.makeFirstResponder(nil)
        // No recipient must never send or clear a draft, and this test never
        // invokes a real prompt, approval or background Codex connection.
        selected = nil; sendPrompt()
        let valid = prompt.stringValue == "Explain this code" && !sending
        if !valid { print("CODEX FIXTURE end-edit",prompt.stringValue,sending) }
        return valid
    }
}

extension CodexAppWidgetView {
    func verifyUsageRing()->Bool {
        guard usage,logo.image != nil else{return false}
        for windows:[CodexUsageWindow] in [[],[.init(used:0,minutes:300,resets:nil)],[.init(used:50,minutes:300,resets:nil),.init(used:92,minutes:10080,resets:nil)],[.init(used:100,minutes:300,resets:nil)]] {
            snapshot.windows=windows;primary.windowValue=windows.first;primary.secondaryValue=windows.dropFirst().first
            for size in [(48,48),(180,120),(292,164),(400,400),(620,160)] {
                frame=NSRect(x:0,y:0,width:size.0,height:size.1);needsLayout=true;layoutSubtreeIfNeeded()
                let ring=primary.convert(primary.ringFrame,to:self)
                guard !primary.isHidden,secondary.isHidden,tinyValue.isHidden,bounds.contains(ring),ring.contains(logo.frame),abs(logo.frame.midX-ring.midX)<0.01,abs(logo.frame.midY-ring.midY)<0.01,logo.frame.width>ring.width*0.5 else{return false}
                guard !containsControl(NSPoint(x:ring.minX,y:ring.midY)) else{return false}
            }
        }
        return true
    }
}
