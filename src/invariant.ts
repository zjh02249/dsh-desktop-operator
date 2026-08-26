/**
 * Package-owned invariant companion for `@valkia/dsh-plugin-computer-use`.
 * @module @valkia/dsh-plugin-computer-use/invariant
 */

/* jscpd:ignore-start */
import type { Context } from '@deepseek-ai/cordis'
import type { InvariantInstaller } from '@deepseek-ai/dsh-invariants'

const PACKAGE_NAME = '@valkia/dsh-plugin-computer-use'

/** Cordis companion plugin name. */
export const name = 'computer-use-invariant'
/** Service required before the companion can reserve package ownership. */
export const inject = ['invariants']

/**
 * No runtime invariant: MCP generation and tool lifecycle belong to
 * `dsh-mcp-client`; action approvals and turn cleanup remain private per instance.
 */
const install: InvariantInstaller = () => {}

/**
 * Register this package's invariant companion.
 * @param ctx - plugin context carrying the invariant registry.
 * @returns the installed registration's disposer.
 */
export const apply = (ctx: Context): Promise<() => void> =>
  Promise.resolve(ctx.invariants.register(PACKAGE_NAME, install))
/* jscpd:ignore-end */
