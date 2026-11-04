package anyparse.check.oracle;

/**
 * What `apq` remembers about the warm server it started for one project: the port it
 * listens on, the pid of the `haxe --wait` process (the liveness probe), and the
 * wall-clock SECOND at which the last typecheck through it began — the watermark the
 * staleness rule is written against.
 */
@:peg @:schema(anyparse.grammar.json.JsonFormat) @:ws
typedef ServerState = {
	var port: Int;
	var pid: Int;
	var compiledAt: Int;
}
