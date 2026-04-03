# toTOML — convert a Nix attrset to TOML text
#
# Supports: strings, integers, booleans, inline lists (scalars),
# nested tables ([section]), and array of tables ([[section]]).
#
# Array of tables: a key whose value is a list of attrsets is rendered
# as repeated [[key]] blocks.  Lists of scalars remain inline arrays.
{ lib }:

let
  inherit (builtins)
    concatStringsSep
    isAttrs
    isBool
    isInt
    isList
    isString
    length
    replaceStrings
    ;
  inherit (lib)
    filterAttrs
    mapAttrsToList
    ;

  # Escape a TOML string value
  escapeStr = s: "\"${replaceStrings [ "\\" "\"" "\n" ] [ "\\\\" "\\\"" "\\n" ] s}\"";

  # True when v is a list of attrsets (→ [[array of tables]])
  isArrayOfTables = v: isList v && length v > 0 && isAttrs (builtins.head v);

  # Format a scalar value (non-table, non-array-of-tables)
  fmtValue =
    v:
    if isBool v then
      (if v then "true" else "false")
    else if isInt v then
      toString v
    else if isString v then
      escapeStr v
    else if isList v then
      "[${concatStringsSep ", " (map fmtValue v)}]"
    else
      throw "toTOML: unsupported value type";

  # Classify values in an attrset
  isScalar = _: v: !(isAttrs v) && !(isArrayOfTables v);
  isTable = _: isAttrs;
  isAoT = _: isArrayOfTables;

  # Render a table's scalar fields as key = value lines
  renderScalars = attrs: mapAttrsToList (k: v: "${k} = ${fmtValue v}") (filterAttrs isScalar attrs);

  # Render a single table block (recursive for nested tables)
  renderTable =
    prefix: attrs:
    let
      scalarLines = renderScalars attrs;
      tables = filterAttrs isTable attrs;
      aots = filterAttrs isAoT attrs;

      tableBlocks = mapAttrsToList (
        k: v:
        let
          fullKey = if prefix == "" then k else "${prefix}.${k}";
        in
        "\n[${fullKey}]\n${renderTable fullKey v}"
      ) tables;

      aotBlocks = mapAttrsToList (
        k: v:
        let
          fullKey = if prefix == "" then k else "${prefix}.${k}";
        in
        concatStringsSep "" (map (entry: "\n[[${fullKey}]]\n${renderTable fullKey entry}") v)
      ) aots;
    in
    concatStringsSep "\n" (scalarLines ++ tableBlocks ++ aotBlocks);

  # Entry point: render top-level attrset
  toTOML = attrs: renderTable "" attrs;

in
toTOML
