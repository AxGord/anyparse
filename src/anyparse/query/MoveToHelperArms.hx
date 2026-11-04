package anyparse.query;

import anyparse.grammar.json.JValue;
import anyparse.query.MoveSymbol.MoveChange;
import anyparse.query.RefactorSupport.TypeDeclMatch;
import anyparse.query.format.json.MutationArmJson;
import anyparse.query.format.json.MutationArmRegistryJsonParser;
import anyparse.runtime.Span;

using Lambda;

/**
 * The mutation-arm RETARGET HINT of `move-to-helper --arms <registry.json>`: which arms address a member the move took
 * out of its type, and which arms' cut no longer occurs in the member it addresses.
 *
 * A hint, not an edit: no op of hxq writes the arm registry, and an arm's `find` text is the author's — a moved body
 * whose `x` became `g.x` may need a different cut, not a mechanically patched one. Read off the CANONICAL
 * rewritten sources (the bytes `--write` lands), because the writer may re-wrap a line a `find` spans.
 */
@:nullSafety(Strict)
@:access(anyparse.query.MoveMember)
@:access(anyparse.query.Patch)
final class MoveToHelperArms {

	/**
	 * One line per arm the move affects: `retarget` for an arm whose `type#method` is a member of `srcTypeName` that left
	 * it for `helperName`, `stale` for an arm (retargeted or not) whose `find` no longer occurs in the member it addresses.
	 * Arms addressing a type no changed file declares are not read.
	 */
	public static function hints(
		armsJson: String, changes: Array<MoveChange>, srcTypeName: String, helperName: String, plugin: GrammarPlugin
	): Array<String> {
		final members: Map<String, Map<String, Array<String>>> = membersByType(changes, plugin);
		final srcFqn: Null<String> = [for (fqn in members.keys()) fqn].find(fqn -> lastSegment(fqn) == srcTypeName);
		final helperFqn: Null<String> = [for (fqn in members.keys()) fqn].find(fqn -> lastSegment(fqn) == helperName);
		final out: Array<String> = [];
		for (arm in MutationArmRegistryJsonParser.parse(armsJson).arms) if (
			(arm.kind ?? 'FnMember') == 'FnMember' && members.exists(arm.type)
		) {
			var type: String = arm.type;
			final srcMembers: Map<String, Array<String>> = members[arm.type] ?? [];
			final helperMembers: Map<String, Array<String>> = helperFqn == null ? [] : members[helperFqn] ?? [];
			if (helperFqn != null && arm.type == srcFqn && !srcMembers.exists(arm.method) && helperMembers.exists(arm.method)) {
				out.push('arm ${arm.name}: retarget "${arm.type}#${arm.method}" -> "$helperFqn#${arm.method}"');
				type = helperFqn;
			}
			final texts: Array<String> = members[type]?.get(arm.method) ?? [];
			final missing: Null<String> = findsOf(arm).find(f -> !texts.exists(t -> occurs(f, t)));
			if (missing != null) out.push('arm ${arm.name}: its find no longer occurs in "$type#${arm.method}" — re-aim it');
		}
		return out;
	}

	private static inline function lastSegment(path: String): String {
		return path.substr(path.lastIndexOf('.') + 1);
	}

	/** Per type a changed file declares (`pkg.Type`), its members' node texts by name. */
	private static function membersByType(changes: Array<MoveChange>, plugin: GrammarPlugin): Map<String, Map<String, Array<String>>> {
		final out: Map<String, Map<String, Array<String>>> = [];
		for (change in changes) {
			final tree: Null<QueryNode> = switch ParseGate.parse(plugin, change.newSource, change.file) {
				case Unparsed(_): null;
				case Parsed(t): t;
			};
			if (tree == null) continue;
			final pkg: String = ModuleScan.packageOf(tree);
			for (node in tree.children) {
				final decl: Null<TypeDeclMatch> = RefactorSupport.typeDeclOf(node);
				if (decl == null) continue;
				final byName: Map<String, Array<String>> = [];
				for (g in MoveMember.membersOf(decl, change.newSource, plugin.refShape(), plugin.lexicalRegions)) {
					final span: Null<Span> = g.member.span;
					final name: Null<String> = g.member.name;
					if (span == null || name == null) continue;
					final texts: Array<String> = byName[name] ?? [];
					texts.push(change.newSource.substring(span.from, span.to));
					byName[name] = texts;
				}
				out[pkg == '' ? decl.name : '$pkg.${decl.name}'] = byName;
			}
		}
		return out;
	}

	private static function findsOf(arm: MutationArmJson): Array<String> {
		return switch arm.find {
			case JString(find): [find];
			case JArray(items): [
				for (item in items) switch item {
					case JString(find): find;
					case _: continue;
				}
			];
			case _: [];
		};
	}

	/**
	 * Whether `fragment` still cuts `text` the way `hxq patch` (and so `tools/mutation-arm.sh`) applies it: exactly once,
	 * byte for byte or on whole lines with their indentation ignored (`Patch.locate`).
	 */
	private static function occurs(fragment: String, text: String): Bool {
		return Patch.locate(text, fragment, 'FnMember', '', false).error == null;
	}

}
