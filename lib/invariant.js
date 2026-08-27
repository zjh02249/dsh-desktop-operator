//#region lib/types/invariant.js
/**
* Package-owned invariant companion for `dsh-desktop-operator`.
* @module dsh-desktop-operator/invariant
*/
const PACKAGE_NAME = "dsh-desktop-operator";
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
