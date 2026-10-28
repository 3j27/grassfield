#!/bin/sh
# Prints the localized values of the desktop entries in the language given as the only argument (the shell's,
# Translator.language: "fr_FR", "fr", "de_DE@euro"...): for each entry that localizes its Name, GenericName, Comment or
# Keywords, one line "id<TAB>Name<TAB>GenericName<TAB>Comment<TAB>Keywords" (Keywords as written, ";"-separated), each value
# picked as the Desktop Entry Specification says: Key[lang_COUNTRY@MODIFIER], Key[lang_COUNTRY], Key[lang@MODIFIER],
# Key[lang], then Key. Quickshell's DesktopEntry picks its localized values from LC_MESSAGES or LANG alone, once, while the
# shell's language can come from elsewhere (LANGUAGE, LC_ALL, GRASSFIELD_LANG): services/Apps.qml writes these on the
# entries. An entry that localizes none of the four keys is the same in every language and is not printed. The traversal
# is hidden-entries.sh's: ids in the form of Quickshell's DesktopEntry.id ("-" for subfolders, no ".desktop"), only the
# highest-priority file per id (XDG_DATA_HOME shadows XDG_DATA_DIRS), CRLF files, "Key = value" spacing, symlinked folders;
# file names containing a newline are skipped. The escapes \s \n \t \r \\ are decoded, and a tab or a line break in a value
# becomes a space. A language that is not of the form lang[_COUNTRY][.ENCODING][@MODIFIER] counts as none: every value is
# the unlocalized one. Read only.
NL='
'
lang=$1
case $lang in
  *[!A-Za-z0-9_.@-]* | '') lang= ;;
esac
IFS=:
{
  for d in "${XDG_DATA_HOME:-$HOME/.local/share}" ${XDG_DATA_DIRS:-/usr/local/share:/usr/share}; do
    [ -d "$d/applications" ] || continue
    case $d in *"$NL"*) continue ;; esac
    printf '/%s/applications/\n' "${d#/}"
    find -L "$d/applications" -name '*.desktop' ! -name "*$NL*" ! -path "*$NL*" -printf '%P\n' 2>/dev/null
  done
} | awk -v lang="$lang" '
  BEGIN {
    keys["Name"] = 1; keys["GenericName"] = 2; keys["Comment"] = 3; keys["Keywords"] = 4
    # lang_COUNTRY.ENCODING@MODIFIER: the encoding is ignored for matching (the specification).
    l = lang; mod = ""; country = ""
    if ((i = index(l, "@")) > 0) { mod = substr(l, i + 1); l = substr(l, 1, i - 1) }
    if ((i = index(l, ".")) > 0) l = substr(l, 1, i - 1)
    sub(/-/, "_", l)
    if ((i = index(l, "_")) > 0) { country = substr(l, i + 1); l = substr(l, 1, i - 1) }
    if (l !~ /^[A-Za-z][A-Za-z][A-Za-z]?$/) { l = ""; country = ""; mod = "" }
    # The score of each locale suffix that matches the language, best first (absent: no match).
    if (l != "") {
      if (country != "" && mod != "") score[l "_" country "@" mod] = 4
      if (country != "") score[l "_" country] = 3
      if (mod != "") score[l "@" mod] = 2
      score[l] = 1
    }
  }
  function decode(v,    out, c, i, n) {
    out = ""
    n = length(v)
    for (i = 1; i <= n; i++) {
      c = substr(v, i, 1)
      if (c == "\\" && i < n) {
        c = substr(v, ++i, 1)
        if (c == "s" || c == "n" || c == "t" || c == "r") c = " "
        else if (c != "\\") c = "\\" c
      } else if (c == "\t" || c == "\r") {
        c = " "
      }
      out = out c
    }
    return out
  }
  function scan(path,    line, grp, k, loc, s, eq, i, v, best, val, localized) {
    split("", best); split("", val)
    localized = 0
    while ((getline line < path) > 0) {
      sub(/[ \t\r]+$/, "", line)
      if (line ~ /^\[/) {
        grp = line
        continue
      }
      if (grp != "[Desktop Entry]" || line !~ /^(Name|GenericName|Comment|Keywords)(\[[^]=]*\])?[ \t]*=/)
        continue
      eq = index(line, "=")
      k = substr(line, 1, eq - 1)
      sub(/[ \t]+$/, "", k)
      loc = ""
      if ((i = index(k, "[")) > 0) {
        loc = substr(k, i + 1, length(k) - i - 1)
        k = substr(k, 1, i - 1)
        localized = 1
      }
      s = loc == "" ? 0 : (loc in score ? score[loc] : -1)
      if (s < 0 || (k in best && best[k] >= s))
        continue
      best[k] = s
      v = substr(line, eq + 1)
      sub(/^[ \t]+/, "", v)
      val[k] = decode(v)
    }
    close(path)
    if (!localized)
      return ""
    return val["Name"] "\t" val["GenericName"] "\t" val["Comment"] "\t" val["Keywords"]
  }
  /^\// { base = $0; next }
  {
    id = $0
    sub(/\.desktop$/, "", id)
    gsub("/", "-", id)
    if (id in seen)
      next
    seen[id] = 1
    out = scan(base $0)
    if (out != "")
      print id "\t" out
  }'
