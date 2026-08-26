//#region lib/types/invariant.js
/**
* Package-owned invariant companion for `@valkia/dsh-plugin-computer-use`.
* @module @valkia/dsh-plugin-computer-use/invariant
*/
const PACKAGE_NAME = "@valkia/dsh-plugin-computer-use";
/** Cordis companion plugin name. */
const name = "computer-use-invariant";
/** Service required before the companion can reserve package ownership. */
const inject = ["invariants"];
/**
* No runtime invariant: MCP generation and tool lifecycle belong to
* `dsh-mcp-client`; action approvals and turn cleanup remain private per instance.
*/
const install = () => {};
/**
* Register this package's invariant companion.
* @param ctx - plugin context carrying the invariant registry.
* @returns the installed registration's disposer.
*/
const apply = (ctx) => Promise.resolve(ctx.invariants.register(PACKAGE_NAME, install));
//#endregion
export { apply, inject, name };
