package anyparse.grammar.mermaid;

/** An edge id with its `@` (`e1@`), written before the link it names (`A e1@--> B`). */
@:re('[^\\s\\[\\](){}|\"<>&;:,~=.\\-@%#]+@(?![{\"])')
@:rawString
abstract MmdEdgeIdLit(String) from String to String {}
