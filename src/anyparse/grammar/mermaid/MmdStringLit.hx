package anyparse.grammar.mermaid;

/** A double-quoted string of a `click` statement (a URL or a tooltip), quotes included. */
@:re('\"[^\"]*\"')
@:rawString
abstract MmdStringLit(String) from String to String {}
