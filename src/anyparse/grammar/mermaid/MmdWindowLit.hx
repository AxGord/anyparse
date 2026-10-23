package anyparse.grammar.mermaid;

/** The browsing context a `click` link opens in: `_blank`, `_self`, `_parent` or `_top`. */
@:re('_(?:blank|self|parent|top)\\b')
@:rawString
abstract MmdWindowLit(String) from String to String {}
