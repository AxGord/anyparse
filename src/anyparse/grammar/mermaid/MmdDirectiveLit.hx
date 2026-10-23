package anyparse.grammar.mermaid;

/** A `%%{ … }%%` directive (`%%{init: {"theme": "dark"}}%%`), kept verbatim. */
@:re('%%\\{[\\s\\S]*?\\}%%')
@:rawString
abstract MmdDirectiveLit(String) from String to String {}
