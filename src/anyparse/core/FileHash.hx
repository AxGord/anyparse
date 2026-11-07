package anyparse.core;

/** A file's path and the hash of its content. */
@:peg typedef FileHash = {
	var path: String;
	var hash: String;
}
