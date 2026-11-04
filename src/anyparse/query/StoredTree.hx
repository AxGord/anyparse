package anyparse.query;

/** The wire form of a tree `ParseDiskCache` keeps: every node as a run of integers over one string table, in pre-order. */
@:peg @:schema(anyparse.grammar.json.JsonFormat) @:ws
typedef StoredTree = {
	final strings: Array<String>;
	final ints: Array<Int>;
}
