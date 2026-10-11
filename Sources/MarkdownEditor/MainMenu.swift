import AppKit

/// The main menu, built in code (there is no nib).
@MainActor
enum MainMenu {
    static func build() -> NSMenu {
        let main = NSMenu()
        main.addItem(submenu(appMenu()))
        main.addItem(submenu(fileMenu()))
        main.addItem(submenu(editMenu()))
        main.addItem(submenu(formatMenu()))
        main.addItem(submenu(viewMenu()))
        let window = windowMenu()
        main.addItem(submenu(window))
        NSApp.windowsMenu = window
        return main
    }

    private static func submenu(_ menu: NSMenu) -> NSMenuItem {
        let item = NSMenuItem(title: menu.title, action: nil, keyEquivalent: "")
        item.submenu = menu
        return item
    }

    static func item(_ title: String, _ action: Selector?, _ key: String = "",
                     _ modifiers: NSEvent.ModifierFlags = [.command]) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = modifiers
        return item
    }

    private static func appMenu() -> NSMenu {
        let name = "Markdown Editor"
        let menu = NSMenu(title: name)
        menu.addItem(item("About \(name)", #selector(NSApplication.orderFrontStandardAboutPanel(_:))))
        menu.addItem(item("Check for Updates…", #selector(EditorMenuActions.checkForUpdates(_:))))
        menu.addItem(item("Check for Updates Automatically", #selector(EditorMenuActions.toggleAutomaticUpdateChecks(_:))))
        menu.addItem(.separator())
        let services = NSMenuItem(title: "Services", action: nil, keyEquivalent: "")
        let servicesMenu = NSMenu(title: "Services")
        services.submenu = servicesMenu
        NSApp.servicesMenu = servicesMenu
        menu.addItem(services)
        menu.addItem(.separator())
        menu.addItem(item("Hide \(name)", #selector(NSApplication.hide(_:)), "h"))
        menu.addItem(item("Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option]))
        menu.addItem(item("Show All", #selector(NSApplication.unhideAllApplications(_:))))
        menu.addItem(.separator())
        menu.addItem(item("Quit \(name)", #selector(NSApplication.terminate(_:)), "q"))
        return menu
    }

    private static func fileMenu() -> NSMenu {
        let menu = NSMenu(title: "File")
        menu.addItem(item("New", #selector(EditorMenuActions.newDocument(_:)), "n"))
        menu.addItem(item("Open…", #selector(EditorMenuActions.openDocument(_:)), "o"))
        let recent = NSMenuItem(title: "Open Recent", action: nil, keyEquivalent: "")
        let recentMenu = NSMenu(title: "Open Recent")
        recentMenu.addItem(item("Clear Menu", #selector(NSDocumentController.clearRecentDocuments(_:))))
        recent.submenu = recentMenu
        // NSDocumentController fills a submenu whose items target clearRecentDocuments.
        menu.addItem(recent)
        menu.addItem(.separator())
        menu.addItem(item("Close Window", #selector(NSWindow.performClose(_:)), "w"))
        menu.addItem(item("Save", #selector(EditorMenuActions.saveDocument(_:)), "s"))
        return menu
    }

    private static func editMenu() -> NSMenu {
        let menu = NSMenu(title: "Edit")
        menu.addItem(item("Undo", Selector(("undo:")), "z"))
        menu.addItem(item("Redo", Selector(("redo:")), "z", [.command, .shift]))
        menu.addItem(.separator())
        menu.addItem(item("Cut", #selector(NSText.cut(_:)), "x"))
        menu.addItem(item("Copy", #selector(NSText.copy(_:)), "c"))
        menu.addItem(item("Paste", #selector(NSText.paste(_:)), "v"))
        menu.addItem(item("Paste and Match Style", #selector(NSTextView.pasteAsPlainText(_:)), "v", [.command, .option, .shift]))
        menu.addItem(item("Select All", #selector(NSText.selectAll(_:)), "a"))
        menu.addItem(.separator())
        let find = NSMenuItem(title: "Find", action: nil, keyEquivalent: "")
        let findMenu = NSMenu(title: "Find")
        let findItem = item("Find…", #selector(NSTextView.performFindPanelAction(_:)), "f")
        findItem.tag = Int(NSFindPanelAction.showFindPanel.rawValue)
        findMenu.addItem(findItem)
        let next = item("Find Next", #selector(NSTextView.performFindPanelAction(_:)), "g")
        next.tag = Int(NSFindPanelAction.next.rawValue)
        findMenu.addItem(next)
        let prev = item("Find Previous", #selector(NSTextView.performFindPanelAction(_:)), "g", [.command, .shift])
        prev.tag = Int(NSFindPanelAction.previous.rawValue)
        findMenu.addItem(prev)
        let useSel = item("Use Selection for Find", #selector(NSTextView.performFindPanelAction(_:)), "e")
        useSel.tag = Int(NSFindPanelAction.setFindString.rawValue)
        findMenu.addItem(useSel)
        find.submenu = findMenu
        menu.addItem(find)
        return menu
    }

    private static func formatMenu() -> NSMenu {
        let menu = NSMenu(title: "Format")
        menu.addItem(item("Bold", #selector(MarkdownFormatActions.toggleBold(_:)), "b"))
        menu.addItem(item("Italic", #selector(MarkdownFormatActions.toggleItalic(_:)), "i"))
        menu.addItem(item("Code", #selector(MarkdownFormatActions.toggleInlineCode(_:)), "`", [.command, .shift]))
        menu.addItem(item("Strikethrough", #selector(MarkdownFormatActions.toggleStrikethrough(_:)), "x", [.command, .shift]))
        menu.addItem(item("Link", #selector(MarkdownFormatActions.insertLink(_:)), "k"))
        menu.addItem(.separator())
        for level in 1...6 {
            let heading = item("Heading \(level)", #selector(MarkdownFormatActions.setHeadingLevel(_:)), "\(level)")
            heading.tag = level
            menu.addItem(heading)
        }
        let paragraph = item("Paragraph", #selector(MarkdownFormatActions.setHeadingLevel(_:)), "0")
        paragraph.tag = 0
        menu.addItem(paragraph)
        return menu
    }

    private static func viewMenu() -> NSMenu {
        let menu = NSMenu(title: "View")
        menu.addItem(item("Toggle Sidebar", #selector(NSSplitViewController.toggleSidebar(_:)), "l", [.command, .shift]))
        return menu
    }

    private static func windowMenu() -> NSMenu {
        let menu = NSMenu(title: "Window")
        menu.addItem(item("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m"))
        menu.addItem(item("Zoom", #selector(NSWindow.performZoom(_:))))
        return menu
    }
}
