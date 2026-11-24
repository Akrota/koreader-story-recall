import sys, zipfile
out = sys.argv[1]; n = int(sys.argv[2])
words = ["Der Hof", "Maras Geheimnis", "Der Wald", "Die Flucht", "Rückkehr", "Das Bündnis der drei Häuser am Fluss", "Verrat", "Im Schatten des Nordturms", "Der Rat", "Winter"]
chapters = []
for i in range(1, n + 1):
    title = f"{words[(i - 1) % len(words)]}" + ("" if i <= len(words) else f" ({i})")
    paras = "".join(f"<p>Kapitel {i}, Absatz {j}. Elias, Mara und Joren reisen weiter durch das Land. " * 5 + "</p>" for j in range(1, 7))
    chapters.append((f"ch{i}.xhtml", title, f'<?xml version="1.0" encoding="utf-8"?><html xmlns="http://www.w3.org/1999/xhtml" xml:lang="de"><head><title>{title}</title></head><body><h1>{title}</h1>{paras}</body></html>'))
items = "".join(f'<item id="c{i}" href="{f}" media-type="application/xhtml+xml"/>' for i, (f, _, _) in enumerate(chapters, 1))
spine = "".join(f'<itemref idref="c{i}"/>' for i in range(1, n + 1))
opf = f'''<?xml version="1.0" encoding="utf-8"?><package xmlns="http://www.idpf.org/2007/opf" version="2.0" unique-identifier="id"><metadata xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:opf="http://www.idpf.org/2007/opf"><dc:title>Die lange Reise</dc:title><dc:creator>Test Autorin</dc:creator><dc:language>de</dc:language><dc:identifier id="id">storyrecall-big-1</dc:identifier><meta name="calibre:series" content="Die Chroniken von Arlen"/><meta name="calibre:series_index" content="4"/></metadata><manifest><item id="ncx" href="toc.ncx" media-type="application/x-dtbncx+xml"/>{items}</manifest><spine toc="ncx">{spine}</spine></package>'''
nav = "".join(f'<navPoint id="n{i}" playOrder="{i}"><navLabel><text>{t}</text></navLabel><content src="{f}"/></navPoint>' for i, (f, t, _) in enumerate(chapters, 1))
ncx = f'<?xml version="1.0" encoding="utf-8"?><ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2005-1"><head><meta name="dtb:uid" content="storyrecall-big-1"/></head><docTitle><text>Die lange Reise</text></docTitle><navMap>{nav}</navMap></ncx>'
with zipfile.ZipFile(out, "w") as z:
    z.writestr("mimetype", "application/epub+zip", compress_type=zipfile.ZIP_STORED)
    z.writestr("META-INF/container.xml", '<?xml version="1.0"?><container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container"><rootfiles><rootfile full-path="content.opf" media-type="application/oebps-package+xml"/></rootfiles></container>')
    z.writestr("content.opf", opf); z.writestr("toc.ncx", ncx)
    for f, _, c in chapters: z.writestr(f, c)
