package anyparse.check.oracle;

/** One file's content hash in a generation record. */
@:peg typedef FileHash = {
	var path: String;
	var hash: String;
}
