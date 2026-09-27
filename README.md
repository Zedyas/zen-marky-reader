# Zen Marky Reader

A simple macOS app for reading Markdown and HTML files. I know this stuff already exists but I just wanted a simple markdown reader instead of having VSCode opening all the time.

---

## Install

Requires macOS 14 or later. The download works on Apple Silicon and Intel Macs.

1. Download the macOS ZIP from [the latest release](https://github.com/Zedyas/zen-marky-reader/releases/latest).
2. Unzip it and move `Zen Marky Reader.app` to Applications.
3. Open Zen Marky Reader.

The app is not notarized yet. If macOS blocks the first launch, try opening it once, then go to System Settings > Privacy & Security and click **Open Anyway**, then **Open**. See [Apple's instructions](https://support.apple.com/en-us/102445) if you need help with this step.

---

## Use

- Open a Markdown or HTML file with **File > Open** (`⌘O`), or drag a file into the app window.
- Use the **Aa** button in the toolbar to choose Native Reader or Book Reader and set light or dark appearance. The same options are in the **View** menu.
- In a Markdown task list, click a checkbox to update its marker in the file. Other document text is read-only.
- Each file opens in its own tab. **File > Open Files In** switches to new windows instead. `⌘T` and `⌘N` add an empty tab or window, and an empty tab lists your recent files.
- `⌘F` finds text in the page. The outline button in the toolbar (`⌥⌘O`) jumps to a heading.
- The page updates when the file changes on disk, so you can keep it open next to your editor. The reload button in the toolbar (`⌘R`) reloads it by hand.
- Tabs that are open when you quit reopen on the next launch, at the same scroll position.
- Mermaid diagrams draw in Markdown (a `mermaid` code block) and in HTML (`<pre class="mermaid">`). The app uses its own bundled copy of Mermaid; the document's scripts still never run.
- Front matter at the top of a Markdown file is hidden; **View > Show Front Matter** shows it as one short line. Hover over a code block to copy it.
- **File > Print** (`⌘P`) and **File > Export as PDF** use a light page layout.
- **Help > Keyboard Shortcuts** (`⌘/`) lists every shortcut.

---

## Build from source

Install Xcode or the Apple Command Line Tools, then run:

```sh
./scripts/build-app.sh
open "dist/Zen Marky Reader.app"
```

Run the tests with:

```sh
./scripts/test.sh
```

---

## License and security

Zen Marky Reader is licensed under [MIT](LICENSE). To report a security issue, see [the security policy](SECURITY.md).
