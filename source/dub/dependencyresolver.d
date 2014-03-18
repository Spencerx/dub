/**
	Dependency configuration/version resolution algorithm.

	Copyright: © 2014 Sönke Ludwig
	License: Subject to the terms of the MIT license, as written in the included LICENSE.txt file.
	Authors: Sönke Ludwig
*/
module dub.dependencyresolver;

import dub.dependency;

import std.algorithm : any, canFind, sort;
import std.array : appender;
import std.conv : to;
import std.exception : enforce;
import std.string : format, indexOf, lastIndexOf;


class DependencyResolver(CONFIGS, CONFIG) {
	static struct TreeNodes {
		string pack;
		CONFIGS configs;
	}

	static struct TreeNode {
		string pack;
		CONFIG config;
	}

	static struct ChildIterationState {
		TreeNode[] configs;
		size_t configIndex;
	}

	static struct GraphIterationState {
		CONFIG[string] visited;
		TreeNode[] stack;
		TreeNode node;
		ChildIterationState[] children;
	}

	CONFIG[string] resolve(TreeNode root)
	{
		static string rootPackage(string p) {
			auto idx = indexOf(p, ":");
			if (idx < 0) return p;
			return p[0 .. idx];
		}

		size_t[string] package_indices;
		CONFIG[][] all_configs;
		void findConfigsRec(TreeNode parent)
		{
			foreach (ch; getChildren(parent)) {
				auto basepack = rootPackage(ch.pack);
				if (basepack in package_indices) continue;

				auto pidx = all_configs.length;
				auto configs = getAllConfigs(basepack);
				enforce(configs.length > 0, format("Found no configurations for package %s.", basepack));
				all_configs ~= configs;
				package_indices[basepack] = pidx;

				foreach (v; all_configs[pidx])
					findConfigsRec(TreeNode(ch.pack, v));
			}
		}
		findConfigsRec(root);

		auto config_indices = new size_t[all_configs.length];
		config_indices[] = 0;

		bool[TreeNode] visited;
		bool validateConfigs(TreeNode parent)
		{
			if (parent in visited) return true;
			visited[parent] = true;
			foreach (ch; getChildren(parent)) {
				auto basepack = rootPackage(ch.pack);
				assert(basepack in package_indices, format("%s not in packages %s", basepack, package_indices));
				auto pidx = package_indices[basepack];
				auto config = all_configs[pidx][config_indices[pidx]];
				auto chnode = TreeNode(ch.pack, config);
				if (!matches(ch.configs, config) || !validateConfigs(chnode))
					return false;
			}
			return true;
		}

		while (true) {
			// check if the current combination of configurations works out
			visited = null;
			if (validateConfigs(root)) {
				CONFIG[string] ret;
				foreach (p, i; package_indices)
					ret[p] = all_configs[i][config_indices[i]];
				return ret;
			}

			// find the next combination of configurations
			foreach_reverse (pi, ref i; config_indices) {
				if (++i >= all_configs[pi].length) i = 0;
				else break;
			}
			enforce(config_indices.any!"a!=0", "Could not find a valid dependency tree configuration.");
		}
	}

	protected abstract CONFIG[] getAllConfigs(string pack);
	protected abstract TreeNodes[] getChildren(TreeNode node);
	protected abstract bool matches(CONFIGS configs, CONFIG config);
}


unittest {
	static class TestResolver : DependencyResolver!(uint[], uint) {
		private TreeNodes[][string] m_children;
		this(TreeNodes[][string] children) { m_children = children; }
		protected override uint[] getAllConfigs(string pack) {
			auto ret = appender!(uint[]);
			foreach (p; m_children.byKey) {
				if (p.length <= pack.length+1) continue;
				if (p[0 .. pack.length] != pack || p[pack.length] != ':') continue;
				auto didx = p.lastIndexOf(':');
				ret ~= p[didx+1 .. $].to!uint;
			}
			ret.data.sort!"a>b"();
			return ret.data;
		}
		protected override TreeNodes[] getChildren(TreeNode node) { return m_children.get(node.pack ~ ":" ~ node.config.to!string(), null); }
		protected override bool matches(uint[] configs, uint config) { return configs.canFind(config); }
	}

	// properly back up if conflicts are detected along the way (d:2 vs d:1)
	with (TestResolver) {
		auto res = new TestResolver([
			"a:0": [TreeNodes("b", [2, 1]), TreeNodes("d", [1]), TreeNodes("e", [2, 1])],
			"b:1": [TreeNodes("c", [2, 1]), TreeNodes("d", [1])],
			"b:2": [TreeNodes("c", [3, 2]), TreeNodes("d", [2, 1])],
			"c:1": [], "c:2": [], "c:3": [],
			"d:1": [], "d:2": [],
			"e:1": [], "e:2": [],
		]);
		assert(res.resolve(TreeNode("a", 0)) == ["b":2u, "c":3u, "d":1u, "e":2u]);
	}

	// handle cyclic dependencies gracefully
	with (TestResolver) {
		auto res = new TestResolver([
			"a:0": [TreeNodes("b", [1])],
			"b:1": [TreeNodes("b", [1])]
		]);
		assert(res.resolve(TreeNode("a", 0)) == ["b":1u]);
	}
}
