package dev;

import haxe.Exception;
import haxe.Json;

using StringTools;

/**
 * The one answer to "what did ONE agent's transcript spend": reads a Claude Code subagent transcript (JSONL, one event per
 * line) into its tool calls (output and input size per tool, hxq subcommand, dev command, git subcommand or plugin call), its
 * model turns (usage fields, one per API message), the slice its prompt names, and the ways it went round hxq (shell reads of
 * repo `.hx`, writes of repo `.hx` outside hxq). Sizes are characters; `CHARS_PER_TOKEN` converts them. Summing and pricing
 * the readings is `TokenReport`.
 */
@:nullSafety(Strict)
final class TokenTranscript {

	/** The rough size of a token in characters, the converter every size of the audit goes through. */
	public static inline final CHARS_PER_TOKEN: Int = 4;

	/** The tool output sizes, in tokens, the audit counts the calls over. */
	public static inline final OVER_SMALL: Int = 2000;

	public static inline final OVER_LARGE: Int = 5000;

	/** How many leading-command rounds of `cd`, `export`, `VAR=` and `rtk` prefixes a command line is stripped of. */
	private static inline final PREFIX_ROUNDS: Int = 6;

	/** How many characters of a command a sample of a bypass keeps. */
	private static inline final SAMPLE_LENGTH: Int = 140;

	private static inline final WORKFLOW_PREFIX: String = 'mcp__plugin_workflow_wf__';
	private static inline final MCP_PREFIX: String = 'mcp__';

	/** The shape of a slice id: a hyphenated word or a letter run with a number. */
	private static inline final SLICE_SHAPE: String = '[A-Z][A-Z0-9]*(?:-[A-Za-z0-9]+)+|[A-Z]+[0-9]+[a-z]?';

	private static inline final HOOK_DENIAL: String = 'PreToolUse:';
	private static inline final BASH: String = 'Bash';
	private static final PROMPT_SLICE: EReg = new EReg('(?:slice|Slice|среза|срезу)\\s+($SLICE_SHAPE)\\b', '');
	private static final DESCRIPTION_SLICE: EReg = new EReg('\\b($SLICE_SHAPE)\\b', '');
	private static final LEADING: EReg = ~/^(cd \S+|export [^;&]+|[A-Za-z_][A-Za-z0-9_]*=\S+)\s*(&&|;|\n)\s*/;
	private static final RTK: EReg = ~/^rtk (proxy )?/;
	private static final ENV: EReg = ~/^([A-Za-z_][A-Za-z0-9_]*=\S+\s+)+(?![&;])/;
	private static final HXQ: EReg = ~/^(?:\S*\/)?(?:hxq|apq)(?:\.js)?\s+([a-z-]+)/;
	private static final NODE_APQ: EReg = ~/^node\s+\S*bin\/apq\.js\s+([a-z-]+)/;
	private static final NODE_DEV: EReg = ~/^node\s+\S*bin\/dev\.js\s+([a-z-]+)/;
	private static final GIT: EReg = ~/^git\s+(?:-C\s+\S+\s+)?([a-z-]+)/;
	private static final REPO_HX: EReg = ~/\/(src|test|tools\/src)\/\S+\.hx$/;
	private static final WRITE_OP: EReg = ~/\b(?:hxq|apq(?:\.js)?)\s+(?:patch|replace-node|add-member|add-element|set-doc|new)\b/;

	/**
	 * The reading of the transcript `text` of the agent `id`; `description` is the agent's one-line task, the fallback for the
	 * slice id when its prompt names none. A line that is not JSON is skipped.
	 */
	public static function read(id: String, text: String, description: Null<String>): AgentReading {
		final agent: AgentReading = {
			id: id,
			slice: null,
			tools: [],
			turns: [],
			hxReads: [],
			hxWrites: [],
			scriptWrites: [],
			deniedReads: [],
			deniedWrites: [],
			writeChars: 0,
			indentChars: 0
		};
		final pending: Map<String, PendingCall> = [];
		final byMessage: Map<String, Int> = [];
		var promptSeen: Bool = false;
		for (line in text.split('\n')) {
			final entry: Null<Entry> = line == '' ? null : parse(line);
			final message: Null<Message> = entry?.message;
			if (entry == null || message == null) continue;
			switch entry.type {
				case 'assistant':
					readAssistant(agent, entry, message, pending, byMessage);
				case 'user':
					if (!promptSeen) {
						promptSeen = true;
						agent.slice = sliceOfPrompt(textOf(message.content)) ?? sliceOfDescription(description);
					}
					readResults(agent, message.content, pending);
				case _:
			}
		}
		return agent;
	}

	/** The slice id the prompt `prompt` names (`slice <ID>` or its Russian spelling), or null. */
	public static function sliceOfPrompt(prompt: String): Null<String> {
		return PROMPT_SLICE.match(prompt) ? PROMPT_SLICE.matched(1) : null;
	}

	/** The first slice-shaped word of an agent's one-line task, or null. */
	public static function sliceOfDescription(description: Null<String>): Null<String> {
		return description != null && DESCRIPTION_SLICE.match(description) ? DESCRIPTION_SLICE.matched(1) : null;
	}

	/** `command` without the `cd`, `export`, `VAR=value` and `rtk` prefixes that precede the program it runs. */
	public static function normalize(command: String): String {
		var line: String = command.trim();
		for (_ in 0...PREFIX_ROUNDS) {
			line = ENV.replace(RTK.replace(LEADING.replace(line, ''), ''), '');
		}
		return line;
	}

	/** The row key of a shell command line (already normalized): `hxq <sub>`, `dev <sub>`, `git <sub>` or `sh <program>`. */
	public static function bashKey(line: String): String {
		if (HXQ.match(line)) return 'hxq ${HXQ.matched(1)}';
		if (NODE_APQ.match(line)) return 'hxq ${NODE_APQ.matched(1)}';
		if (NODE_DEV.match(line)) return 'dev ${NODE_DEV.matched(1)}';
		if (GIT.match(line)) return 'git ${GIT.matched(1)}';
		final program: String = line.split(' ')[0];
		return 'sh ${program.substr(program.lastIndexOf('/') + 1)}';
	}

	/** The number of leading space and tab characters on the lines of `text`. */
	public static function indentation(text: String): Int {
		var total: Int = 0;
		for (line in text.split('\n')) total += line.length - line.ltrim().length;
		return total;
	}

	private static inline function sample(segment: Null<String>): Null<String> {
		return segment?.substr(0, SAMPLE_LENGTH);
	}

	private static function readAssistant(
		agent: AgentReading, entry: Entry, message: Message, pending: Map<String, PendingCall>, byMessage: Map<String, Int>
	): Void {
		for (block in blocksOf(message.content)) if (block.type == 'tool_use') readCall(agent, block, pending, entry.cwd);
		final usage: Null<Usage> = message.usage;
		final id: Null<String> = message.id;
		final model: String = message.model ?? '';
		if (usage == null || id == null || model.startsWith('<')) return;
		final at: Float = js.lib.Date.parse(entry.timestamp ?? '');
		final created: Null<CacheCreation> = usage.cache_creation;
		final turn: TurnReading = {
			model: model,
			start: at,
			end: at,
			input: usage.input_tokens ?? 0,
			output: usage.output_tokens ?? 0,
			cacheRead: usage.cache_read_input_tokens ?? 0,
			write5m: created == null ? usage.cache_creation_input_tokens ?? 0 : created.ephemeral_5m_input_tokens ?? 0,
			write1h: created?.ephemeral_1h_input_tokens ?? 0
		};
		final seen: Null<Int> = byMessage[id];
		if (seen == null) {
			byMessage[id] = agent.turns.length;
			agent.turns.push(turn);
		} else {
			// one API message is written once per content block, each copy carrying the same usage: the last copy is complete
			turn.start = agent.turns[seen].start;
			agent.turns[seen] = turn;
		}
	}

	private static function readCall(agent: AgentReading, block: Block, pending: Map<String, PendingCall>, cwd: Null<String>): Void {
		final input: Input = block.input ?? {};
		final name: String = block.name ?? '';
		final command: String = input.command ?? '';
		final line: String = normalize(command);
		final key: String = switch name {
			case BASH: bashKey(line);
			case 'Read': (input.file_path ?? '').endsWith('.hx') ? 'Read .hx' : 'Read other';
			case _: pluginKey(name);
		};
		pending[block.id ?? ''] = { key: key, inChars: Json.stringify(input).length, access: accessOf(name, input, cwd, agent.slice) };
		final payload: String = switch name {
			case BASH:
				WRITE_OP.match(line) ? command : '';
			case 'Edit', 'Write':
				(input.new_string ?? '') + (input.content ?? '');
			case _:
				'';
		};
		agent.writeChars += payload.length;
		agent.indentChars += indentation(payload);
	}

	private static function readResults(agent: AgentReading, content: Null<Any>, pending: Map<String, PendingCall>): Void {
		for (block in blocksOf(content)) {
			final call: Null<PendingCall> = block.type == 'tool_result' ? pending[block.tool_use_id ?? ''] : null;
			if (call == null) continue;
			final stat: ToolStat = agent.tools[call.key] ?? {
				calls: 0,
				inChars: 0,
				outChars: 0,
				over2k: 0,
				over5k: 0
			};
			final answer: String = textOf(block.content);
			final size: Int = answer.length;
			stat.calls++;
			stat.inChars += call.inChars;
			stat.outChars += size;
			if (size > OVER_SMALL * CHARS_PER_TOKEN) stat.over2k++;
			if (size > OVER_LARGE * CHARS_PER_TOKEN) stat.over5k++;
			agent.tools[call.key] = stat;
			record(agent, call.access, block.is_error == true && answer.startsWith(HOOK_DENIAL));
		}
	}

	/** The text of a message content: the string itself, or the `text` parts of a block list joined. */
	private static function textOf(content: Null<Any>): String {
		return content is String ? cast content : [for (block in blocksOf(content)) block.text ?? ''].join('');
	}

	private static function parse(line: String): Null<Entry> {
		return try Json.parse(line) catch (_: Exception) null;
	}

	/** The content blocks of a message content, none when the content is a plain string. */
	private static function blocksOf(content: Null<Any>): Array<Block> {
		return content is Array ? cast content : [];
	}

	/** The row key of a call to a tool that is not the shell or a file read: a workflow or other MCP call, else the tool's name. */
	private static function pluginKey(name: String): String {
		if (name.startsWith(WORKFLOW_PREFIX)) return 'wf ${name.substr(WORKFLOW_PREFIX.length)}';
		return name.startsWith(MCP_PREFIX) ? 'mcp ${name.substr(MCP_PREFIX.length)}' : name;
	}

	/** What a call would be as a way round hxq: the matching shell segment, or the tool and path of an `Edit` / `Write`. */
	private static function accessOf(name: String, input: Input, cwd: Null<String>, slice: Null<String>): Access {
		final command: String = input.command ?? '';
		final path: String = input.file_path ?? '';
		return switch name {
			case BASH:
				{
					read: sample(ShellHxAccess.readSegment(command, cwd, slice)),
					write: sample(ShellHxAccess.writeSegment(command, cwd, slice)),
					script: sample(ShellHxAccess.scriptSegment(command, cwd, slice))
				};
			case 'Edit', 'Write':
				{ read: null, write: REPO_HX.match(path) && ShellHxAccess.isRepoPath(path, slice) ? '$name $path' : null, script: null };
			case _:
				{ read: null, write: null, script: null };
		};
	}

	/** Count `access` as a way round hxq, or as an attempt the gate hook denied (which never ran). */
	private static function record(agent: AgentReading, access: Access, denied: Bool): Void {
		final read: Null<String> = access.read;
		final write: Null<String> = access.write;
		final script: Null<String> = access.script;
		if (read != null) (denied ? agent.deniedReads : agent.hxReads).push(read);
		if (write != null) (denied ? agent.deniedWrites : agent.hxWrites).push(write);
		if (script != null) (denied ? agent.deniedWrites : agent.scriptWrites).push(script);
	}

}

/** One agent's transcript, read. */
typedef AgentReading = {
	var id: String;

	/** The slice its prompt (else its task line) names. */
	var slice: Null<String>;

	var tools: Map<String, ToolStat>;
	var turns: Array<TurnReading>;

	/** The shell commands that read a repo `.hx` with `cat`/`sed -n`/`head`/`tail`. */
	var hxReads: Array<String>;

	/** The commands and tool calls that wrote a repo `.hx` outside hxq. */
	var hxWrites: Array<String>;

	/** The interpreter scripts run in a repo directory that name a `.hx` and call a write: a heuristic. */
	var scriptWrites: Array<String>;

	/** The reads and writes the gate hook denied: attempts that never ran. */
	var deniedReads: Array<String>;

	var deniedWrites: Array<String>;

	/** The characters of the write payloads (hxq write ops, `Edit`, `Write`) and the leading blanks among them. */
	var writeChars: Int;

	var indentChars: Int;
}

/** The calls of one kind and the sizes of what they sent and got back. */
typedef ToolStat = {
	var calls: Int;
	var inChars: Int;
	var outChars: Int;

	/** The calls whose output was over `OVER_SMALL` / `OVER_LARGE` tokens. */
	var over2k: Int;

	var over5k: Int;
}

/** One API message of an agent: when it began and ended (ms since the epoch) and its usage fields. */
typedef TurnReading = {
	var model: String;
	var start: Float;
	var end: Float;
	var input: Int;
	var output: Int;
	var cacheRead: Int;

	/** The tokens written to the 5-minute and the 1-hour cache. */
	var write5m: Int;

	var write1h: Int;
}

/** A tool call seen and not yet answered. */
private typedef PendingCall = {
	var key: String;
	var inChars: Int;
	var access: Access;
}

/** The samples a call gives to the bypass counts, each null when the call is not that kind of access. */
private typedef Access = {
	var read: Null<String>;
	var write: Null<String>;
	var script: Null<String>;
}

/** One line of a transcript, as far as the audit reads it. */
private typedef Entry = {
	var ?type: String;
	var ?timestamp: String;

	/** The directory the agent's shell was in. */
	var ?cwd: String;
	var ?message: Message;
}

private typedef Message = {
	var ?id: String;
	var ?model: String;

	/** A string (the prompt) or a list of blocks. */
	var ?content: Any;

	var ?usage: Usage;
}

private typedef Block = {
	var ?type: String;
	var ?id: String;
	var ?name: String;
	var ?input: Input;
	var ?tool_use_id: String; // noqa: naming
	var ?is_error: Bool; // noqa: naming
	var ?text: String;
	var ?content: Any;
}

/** The fields of a tool call's input the audit looks at, whichever the tool. */
private typedef Input = {
	var ?command: String;
	var ?file_path: String; // noqa: naming
	var ?new_string: String; // noqa: naming
	var ?content: String;
}

private typedef Usage = {
	var ?input_tokens: Int; // noqa: naming
	var ?output_tokens: Int; // noqa: naming
	var ?cache_read_input_tokens: Int; // noqa: naming
	var ?cache_creation_input_tokens: Int; // noqa: naming
	var ?cache_creation: CacheCreation; // noqa: naming
}

private typedef CacheCreation = {
	var ?ephemeral_5m_input_tokens: Int; // noqa: naming
	var ?ephemeral_1h_input_tokens: Int; // noqa: naming
}
