with open("lib/editor.dart", "r") as f:
    content = f.read()

replacement = """  final bool isFocused;
  final Color textColor;
  final double rowHeight = 20.0;
  final double charWidth = 8.4;"""

content = content.replace("""  final bool isFocused;
  final Color textColor;""", replacement)

content = content.replace("if (hasFocus && cursorRow >=", "if (isFocused && cursorRow >=")

with open("lib/editor.dart", "w") as f:
    f.write(content)

print("done")
