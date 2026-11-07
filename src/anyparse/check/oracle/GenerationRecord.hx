package anyparse.check.oracle;

import anyparse.core.FileHash;

/**
 * The persisted record of a successful generation. Every field is optional: a record of another scheme comes off disk
 * too, and it may carry any part of this one.
 */
@:peg @:schema(anyparse.grammar.json.JsonFormat) @:ws
typedef GenerationRecord = {

	/** The record scheme it was written under (`FORMAT_TAG`): a record of another scheme is never current. */
	var ?format: String;
	var ?command: String;
	var ?inputs: Array<FileHash>;
	var ?outputs: Array<FileHash>;

	/** The files the generated hxml depends on without declaring them — see `implicitInputs`. */
	var ?implicit: Array<FileHash>;

}
