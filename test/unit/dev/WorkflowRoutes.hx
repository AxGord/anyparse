package unit.dev;

import sys.io.File;

using StringTools;

/** One state of a tracked workflow: its own scalar keys, the three routing/setting maps, and its text without comment lines. */
typedef WorkflowState = {

	final name: String;

	/** The scalar keys at the state's own level (`type`, `on_success`, `on_error`, `default`, ...): the value, unquoted. */
	final fields: Map<String, String>;

	/** `cases:` — exit code to the next state. */
	final cases: Map<String, String>;

	/** `transitions:` — the label an ask state offers to the state it goes to. */
	final transitions: Map<String, String>;

	/** `context_set:` — key to the value template. */
	final contextSet: Map<String, String>;

	/** Every line of the state but a comment-only line outside a block scalar: what a `{{context.key}}` read can sit in. */
	final text: String;

}

/** The line-by-line reading of one file: the state being read, the key its last four-space line opened, and the states done. */
@:nullSafety(Strict)
private final class StateReader {

	private static inline final KEY_INDENT: Int = 4;
	private static final STATE_HEAD: EReg = ~/^  ([A-Za-z0-9_]+):\s*$/;
	private static final FIELD_LINE: EReg = ~/^    ([A-Za-z0-9_]+):(?: +(.*))?$/;
	private static final ENTRY_LINE: EReg = ~/^      ("[^"]*"|[A-Za-z0-9_]+):(?: +(.*))?$/;

	private final _done: Map<String, WorkflowState> = [];

	private var _inStates: Bool = false;
	private var _name: String = '';
	private var _lines: Array<String> = [];
	private var _fields: Map<String, String> = [];
	private var _entries: Map<String, Map<String, String>> = newEntries();
	private var _key: String = '';
	private var _block: Bool = false;

	public function new() {}

	public function feed(line: String): Void {
		final trimmed: String = line.trim();
		if (trimmed != '' && !line.startsWith(' ') && !line.startsWith('#')) {
			flush();
			_inStates = line.startsWith('states:');
		} else if (opensState(line)) {
			flush();
			_name = STATE_HEAD.matched(1);
		} else if (_name != '') {
			inside(line, trimmed);
		}
	}

	public function finish(): Map<String, WorkflowState> {
		flush();
		return _done;
	}

	private function inside(line: String, trimmed: String): Void {
		final indent: Int = line.length - line.ltrim().length;
		if (_block && (trimmed == '' || indent > KEY_INDENT)) {
			_lines.push(line);
			return;
		}
		_block = false;
		if (trimmed.startsWith('#')) return;
		_lines.push(line);
		if (indent == KEY_INDENT && FIELD_LINE.match(line)) {
			_key = FIELD_LINE.matched(1);
			final raw: String = (FIELD_LINE.matched(2) ?? '').trim();
			_fields[_key] = scalar(raw);
			_block = raw.startsWith('|') || raw.startsWith('>');
		} else if (indent == KEY_INDENT + 2 && ENTRY_LINE.match(line)) {
			final group: Null<Map<String, String>> = _entries[_key];
			if (group != null) group[scalar(ENTRY_LINE.matched(1))] = scalar(ENTRY_LINE.matched(2) ?? '');
		}
	}

	private function flush(): Void {
		if (_name != '') _done.set(_name, {
			name: _name,
			fields: _fields,
			cases: entriesOf('cases'),
			transitions: entriesOf('transitions'),
			contextSet: entriesOf('context_set'),
			text: _lines.join('\n')
		});
		_name = '';
		_lines = [];
		_fields = [];
		_entries = newEntries();
		_key = '';
		_block = false;
	}

	private function opensState(line: String): Bool {
		return _inStates && STATE_HEAD.match(line);
	}

	private function entriesOf(group: String): Map<String, String> {
		final none: Map<String, String> = [];
		return _entries[group] ?? none;
	}

	private static function newEntries(): Map<String, Map<String, String>> {
		return ['cases' => [], 'transitions' => [], 'context_set' => []];
	}

	private static function scalar(raw: String): String {
		final value: String = raw.trim();
		if (value.startsWith('"')) {
			final end: Int = value.indexOf('"', 1);
			return end < 0 ? value : value.substring(1, end);
		}
		final hash: Int = value.indexOf(' #');
		return (hash < 0 ? value : value.substring(0, hash)).trim();
	}

}

/**
 * The one answer to "what routes does a tracked workflow file declare, and which state reads a key": the `states:` of a
 * `.claude/workflows/*.yaml` read into `WorkflowState`s.
 *
 * No YAML grammar exists in the project, so this reads the layout the folder keeps — a state at two spaces, its keys at four,
 * the entries of `cases`, `transitions` and `context_set` at six, a block scalar (`|`, `>`) as text; an inline `{ ... }`
 * stays a scalar. A line that fits none of these is not read, so a state written another way is invisible here, never
 * misread.
 */
@:nullSafety(Strict)
final class WorkflowRoutes {

	public static function statesOf(file: String): Map<String, WorkflowState> {
		final reader: StateReader = new StateReader();
		for (line in File.getContent(file).split('\n')) reader.feed(line);
		return reader.finish();
	}

	/** Where a state goes when it did not exit 0: a case other than `"0"`, `default`, `on_error`, `on_timeout`. */
	public static function failureTargets(state: WorkflowState): Array<String> {
		final out: Array<String> = [ for (code => target in state.cases) if (code != '0') target ];
		for (field in ['default', 'on_error', 'on_timeout']) {
			final target: Null<String> = state.fields[field];
			if (target != null) out.push(target);
		}
		return out;
	}

	/** Every state this one can go to. */
	public static function targetsOf(state: WorkflowState): Array<String> {
		final out: Array<String> = failureTargets(state);
		for (field in ['on_success', 'on_exhausted']) {
			final target: Null<String> = state.fields[field];
			if (target != null) out.push(target);
		}
		for (target in state.cases) out.push(target);
		for (target in state.transitions) out.push(target);
		return out;
	}

	/** The state `state` goes to when its step ends with `code`. */
	public static function nextOf(state: WorkflowState, code: Int): Null<String> {
		return state.cases['$code'] ?? (
			code == 0 ? state.fields['on_success'] : null
		) ?? state.fields['default'] ?? state.fields['on_error'];
	}

	/** Whether the text of `state` mentions `context.<key>`. */
	public static function reads(state: WorkflowState, key: String): Bool {
		return new EReg('context\\.$key\\b', '').match(state.text);
	}

	/**
	 * Every state on a route from `target` that reads `key`, never through `origin` (a retry reads what its earlier
	 * runs left, by design) and never past a state that sets `key`.
	 */
	public static function readersOn(states: Map<String, WorkflowState>, origin: String, target: String, key: String): Array<String> {
		final found: Array<String> = [];
		final seen: Map<String, Bool> = [origin => true];
		final queue: Array<String> = [target];
		while (queue.length > 0) {
			final at: String = queue.shift() ?? break;
			if (seen.exists(at)) continue;
			seen[at] = true;
			final state: Null<WorkflowState> = states[at];
			if (state == null) continue;
			if (reads(state, key)) found.push(at);
			if (!state.contextSet.exists(key)) for (next in targetsOf(state)) queue.push(next);
		}
		return found;
	}

}
