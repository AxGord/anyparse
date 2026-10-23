package anyparse.grammar.mermaid;

import anyparse.format.SameLinePolicy;
import anyparse.format.WriteOptions;

/**
 * Write options of the Mermaid flowchart writer: the base `WriteOptions` plus the statement separator.
 */
typedef MermaidWriteOptions = WriteOptions & {

	/**
	 * What precedes every statement after the first. Mermaid separates statements by a line break
	 * (or `;`), so `Next` is the only value whose output is Mermaid; the knob exists because the
	 * writer's per-element separator is declared through a `SameLinePolicy`.
	 */
	var statementBreak: SameLinePolicy;
}
