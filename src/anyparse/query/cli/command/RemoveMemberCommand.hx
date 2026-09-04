package anyparse.query.cli.command;

import anyparse.query.cli.CliContext;
import haxe.Exception;
import anyparse.query.ExitCode.*;

using StringTools;

/**
 * A member named the way `RemoveMember` addresses one: the enclosing type's name and the
 * member's own. A `--select` / `--match` address on `remove-member` resolves to a NODE, and
 * this is what that node is reduced to — the removal itself stays BY NAME (every conditional
 * twin of the name goes with it), so an address is a way to SPELL the pair, never a way to
 * remove one branch's declaration and leave its twin behind.
 */
typedef NamedMember = {
	final type: String;
	final member: String;
};

/**
 * `apq remove-member` — remove a member by --type + name (inverse of add-member).
 *
 * An ADDRESSED EDIT: one addressed node in one file, out through `CliEdit`'s address
 * resolution and its `--write` / preview tail.
 */
@:nullSafety(Strict)
final class RemoveMemberCommand implements CliCommand {

	public function new() {}

	public function name(): String {
		return 'remove-member';
	}

	public function summary(): String {
		return 'Remove a member by --type + name (inverse of add-member)';
	}

	public function run(args: Array<String>, ctx: CliContext): Int {
		return runRemoveMember(args);
	}

	public function usage(): Void {
		printRemoveMemberUsage();
	}

	/**
	 * `apq remove-member <file> (--select <sel> | --match <pattern> | --type <T> <memberName>)
	 * [--reformat] [--write]` — remove a member (a field or method) with its modifier / meta
	 * group. The member is addressed either by the v2 forms every sibling op takes or by the
	 * by-name `--type <T> <memberName>` pair; giving both is a usage error, and an address is
	 * reduced to that same pair by `resolveMemberAddress`, so it SPELLS the removal rather than
	 * narrowing it. `<memberName>` may resolve to SEVERAL declarations, when
	 * conditional-compilation regions declare it once per build — those are one logical member
	 * and all of them go, each with its leading doc comment unless `--keep-doc` says otherwise.
	 * The by-name counterpart of `add-member`.
	 */
	private static function runRemoveMember(args: Array<String>): Int {
		var lang: String = 'haxe';
		var write: Bool = false;
		var reformat: Bool = false;
		var withDoc: Bool = true;
		var typeName: Null<String> = null;
		var file: Null<String> = null;
		var memberName: Null<String> = null;
		var selectExpr: Null<String> = null;
		var matchExpr: Null<String> = null;
		var nth: Null<Int> = null;

		var i: Int = 0;
		while (i < args.length) {
			final a: String = args[i];
			switch a {
				case '--lang':
					lang = CliArgs.expectValue(args, ++i, '--lang');
				case '--type':
					typeName = CliArgs.expectValue(args, ++i, '--type');
				case '--select':
					selectExpr = CliArgs.expectValue(args, ++i, '--select');
				case '--match':
					matchExpr = CliArgs.expectValue(args, ++i, '--match');
				case '--nth':
					nth = Std.parseInt(CliArgs.expectValue(args, ++i, '--nth'));
				case '--write':
					write = true;
				case '--reformat':
					reformat = true;
				case '--with-doc':
					// Accepted and inert: taking the doc is the default now. Kept so an
					// existing script that spells the old opt-in keeps working.
					withDoc = true;
				case '--keep-doc':
					withDoc = false;
				case '-h', '--help':
					printRemoveMemberUsage();
					return EXIT_OK;
				case _:
					if (a.startsWith('--')) {
						CliIo.stderr('apq remove-member: unknown option "$a"\n');
						return EXIT_USAGE;
					}
					if (file == null)
						file = a;
					else if (memberName == null)
						memberName = a;
					else {
						CliIo.stderr('apq remove-member: unexpected extra argument "$a"\n');
						return EXIT_USAGE;
					}
			}
			i++;
		}
		final addressed: Bool = selectExpr != null || matchExpr != null;
		final byName: Null<NamedMember> = typeName != null && memberName != null ? { type: typeName, member: memberName } : null;
		if (addressed && (typeName != null || memberName != null)) {
			CliIo.stderr('apq remove-member: give either --select / --match or --type <T> <memberName>, not both\n');
			return EXIT_USAGE;
		}
		if (file == null || (!addressed && byName == null)) {
			CliIo.stderr("apq remove-member: expected <file> (--select '<sel>' | --match '<pattern>' | --type <T> <memberName>)\n");
			printRemoveMemberUsage();
			return EXIT_USAGE;
		}

		final filePath: String = file;
		final source: String = try CliIo.readFile(filePath) catch (exception: Exception) {
			CliIo.stderr('apq remove-member: $filePath: ${exception.message}\n');
			return EXIT_RUNTIME;
		};
		// The caching plugin so the address resolution's parse is the one `RemoveMember` reparses.
		final plugin: GrammarPlugin = new CachingGrammarPlugin(CliArgs.pickPlugin(lang));
		// One spelling of the op name for both seats — a third copy of the literal is what
		// `string-literal-dup` counts, and the address resolver prefixes its own diagnostics with it.
		final op: String = 'remove-member';
		final named: Null<NamedMember> = addressed ? resolveMemberAddress(op, source, plugin, selectExpr, matchExpr, nth) : byName;
		if (named == null) return EXIT_RUNTIME;
		final target: NamedMember = named;
		final optsJson: Null<String> = CliArgs.discoverFormatConfig(filePath);
		return CliEdit.finishEdit(
			op, filePath, write, RemoveMember.removeMember(source, target.type, target.member, reformat, plugin, withDoc, optsJson)
		);
	}

	private static function printRemoveMemberUsage(): Void {
		CliIo.sysPrint("Usage: apq remove-member <file> (--select '<sel>' | --match '<pattern>' | --type <T> <memberName>) [options]\n");
		CliIo.sysPrint('\n');
		CliIo.sysPrint('Remove a member (a field or method) with its modifier / meta group. When the\n');
		CliIo.sysPrint('name is declared in several conditional-compilation branches, ALL of those\n');
		CliIo.sysPrint('declarations go — they are one logical member — and a region left with no\n');
		CliIo.sysPrint('member takes its directives with it. The by-name counterpart of add-member.\n');
		CliIo.sysPrint('\n');
		CliIo.sysPrint('The member is addressed either by the v2 forms the sibling ops take or by\n');
		CliIo.sysPrint('--type <T> <memberName>; giving both is a usage error. An address resolves\n');
		CliIo.sysPrint('to ONE node and is reduced to the (type, member) name pair — so it is a way\n');
		CliIo.sysPrint('to SPELL that pair, not a way to remove one branch and keep its twin.\n');
		CliIo.sysPrint('\n');
		CliIo.sysPrint('Options:\n');
		CliIo.sysPrint("  --select <sel>  Selector path for the member, e.g. 'ClassDecl:C >> FnMember:f'\n");
		CliIo.sysPrint('  --match <pat>   apq search pattern; the member holding the hit is the target\n');
		CliIo.sysPrint('  --nth <k>       Pick the k-th (1-based) --select / --match candidate\n');
		CliIo.sysPrint('  --type <T>      The enclosing type (with <memberName>, the by-name form)\n');
		CliIo.sysPrint('  --keep-doc      Leave the member\'s leading doc comment behind\n');
		CliUsage.printEditOptionsTail();
	}

	/**
	 * Resolve a `--select` / `--match` address to the (enclosing type, member) NAME pair
	 * `RemoveMember` takes — the v2 addressing forms every sibling op accepts, on the one op that
	 * had only `--type <T> <memberName>`. Three workers independently reached for
	 * `remove-member --select 'FnMember:x'` and were sent to `remove-element` instead.
	 *
	 * The resolved node is LIFTED to its innermost enclosing field member, so an address that
	 * points inside a body (`--match` on a statement) still names the member that holds it; the
	 * type is then the nearest enclosing declaration `RefactorSupport.typeDeclOf` recognises,
	 * which is what makes a `final class`'s inner `ClassForm` answer with the outer name.
	 *
	 * The pair is only a SPELLING of what the by-name removal already did: every conditional twin
	 * of the name goes, whichever branch's declaration the address happened to land on. An address
	 * that reaches no member, or a member outside any named type, is a refusal naming the resolved
	 * kind rather than a silently different removal.
	 */
	private static function resolveMemberAddress(
		op: String, source: String, plugin: GrammarPlugin, select: Null<String>, matchPat: Null<String>, nth: Null<Int>
	): Null<NamedMember> {
		final tree: Null<QueryNode> = try plugin.parseFile(source) catch (exception: Exception) null;
		if (tree == null) {
			CliIo.stderr('apq $op: source does not parse\n');
			return null;
		}
		final root: QueryNode = tree;
		final resolved: Null<QueryNode> = switch Address.resolve(root, source, plugin, {
			select: select,
			match: matchPat,
			nth: nth
		}) {
			case Ok(_, node):
				node;
			case Err(message):
				CliIo.stderr('apq $op: $message\n');
				null;
		};
		if (resolved == null) return null;
		final path: Null<Array<QueryNode>> = TreePath.pathTo(root, resolved);
		if (path == null) {
			CliIo.stderr('apq $op: the resolved node is not in this file\n');
			return null;
		}
		final chain: Array<QueryNode> = path;
		var member: Null<String> = null;
		var i: Int = chain.length - 1;
		while (i >= 0) {
			final node: QueryNode = chain[i];
			final name: Null<String> = node.name;
			if (name != null && RefactorSupport.isFieldMemberKind(node.kind)) {
				member = name;
				break;
			}
			i--;
		}
		if (member == null) {
			CliIo.stderr(
				'apq $op: the resolved ${resolved.kind} node is not a type member — use `apq remove-element` for a statement or element\n'
			);
			return null;
		}
		var typeName: Null<String> = null;
		var j: Int = i - 1;
		while (j >= 0) {
			final found: Null<RefactorSupport.TypeDeclMatch> = RefactorSupport.typeDeclOf(chain[j]);
			if (found != null) {
				typeName = found.name;
				break;
			}
			j--;
		}
		if (typeName == null) {
			CliIo.stderr('apq $op: the member "$member" is not inside a named type\n');
			return null;
		}
		CliIo.stderr('apq $op: target $typeName.$member\n');
		return { type: typeName, member: member };
	}

}
