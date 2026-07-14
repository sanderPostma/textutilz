with open("lib/editor.dart", "r") as f:
    content = f.read()

# 1. Remove const from TextStyle
content = content.replace("const TextStyle(", "TextStyle(")

# 2. Add rowHeight and charWidth back to the EditorPainter constructor because it's easier, or just remove them from the build call.
# Wait, I already added them as class properties in the painter. Let's see how it is called in build.
content = content.replace("              rowHeight: _rowHeight,\n", "")
content = content.replace("              charWidth: _charWidth,\n", "")

with open("lib/editor.dart", "w") as f:
    f.write(content)

print("done")
