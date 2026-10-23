package anyparse.grammar.mermaid;

/** The links a `linkStyle` restyles: `default`, or link ordinals (`0,1,4`). */
@:re('default\\b|[0-9]+(?:,[0-9]+)*')
@:rawString
abstract MmdLinkTargetsLit(String) from String to String {}
