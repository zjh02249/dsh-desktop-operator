/**
 * Agent-scoped local desktop Computer Use plugin. It launches the package-local
 * Open Computer Use MCP server, registers its Codex-compatible tools through
 * `dsh-mcp-client`, gates real-desktop access, and clears transient desktop
 * state when an agent turn ends.
 * @module dsh-desktop-operator
 */
import type { Context } from '@deepseek-ai/cordis';
import z from '@deepseek-ai/schemastery';
import type { ReconnectConfig } from '@deepseek-ai/dsh-mcp-client';
/** Cordis plugin name used by Loader diagnostics. */
export declare const name = "computer-use";
/** Services required by the plugin and its MCP bridge. */
export declare const inject: string[];
/** Stable MCP namespace, matching the Computer Use family in tool names. */
export declare const COMPUTER_USE_SERVER_NAME = "computer_use";
/** Public-name prefix assigned by `dsh-mcp-client` to every Computer Use tool. */
export declare const COMPUTER_USE_TOOL_PREFIX = "mcp__computer_use__";
/** Access policy applied before any Computer Use MCP tool dispatches. */
export type ComputerUseAccessPolicy = 'per-call' | 'allow';
/** Policy for semantically high-risk desktop actions after ordinary desktop access is admitted. */
export type ComputerUseHighRiskActionPolicy = 'confirm' | 'deny' | 'allow';
/** Intent kinds accepted by every mutating Computer Use tool. */
export type ComputerUseActionIntentKind = 'navigate' | 'edit' | 'select' | 'move' | 'dismiss' | 'send' | 'submit' | 'publish' | 'delete' | 'purchase' | 'approve' | 'upload' | 'change_access' | 'expose_sensitive_data' | 'install';
export type ComputerUseActionRisk = {
    level: 'none';
} | {
    level: 'unclassified';
} | {
    level: 'low' | 'high';
    kind: ComputerUseActionIntentKind;
    summary: string;
};
/** Windows interaction strategy for focus-sensitive automation. */
export type ComputerUseInteractionMode = 'foreground-verified' | 'background-best-effort';
/** Plugin configuration. */
export interface Config {
    /** Desktop-access approval mode. `per-call` keeps every accepted action one-shot. */
    accessPolicy?: ComputerUseAccessPolicy;
    /** Handling for final high-risk actions when accessPolicy does not already prompt per call. */
    highRiskActionPolicy?: ComputerUseHighRiskActionPolicy;
    /** Preferred runtime interaction strategy for focus-sensitive desktop control. */
    interactionMode?: ComputerUseInteractionMode;
    /** Whether the runtime may launch the target application when it is not already running. */
    allowAppLaunch?: boolean;
    /** Show a click-through desktop banner and cursor halo while Computer Use controls Windows. */
    visualIndicator?: boolean;
    /** Per-MCP-tool deadline in milliseconds. */
    toolCallTimeoutMs?: number;
    /** Whether initial MCP launch or tool discovery failure rejects plugin activation. */
    failOnStartupError?: boolean;
    /** Automatic reconnect policy after the native MCP process exits unexpectedly. */
    reconnect?: ReconnectConfig;
    /** Explicit environment entries for the native runtime, merged over the MCP bridge's scrubbed parent env. */
    env?: Record<string, string>;
    /** Absolute path to a local development runtime binary; empty uses the packaged native runtime. */
    runtimeExecutable?: string;
    /** Working directory for the native runtime; empty lets the transport use its default. */
    cwd?: string;
    /** Send the runtime's turn-ended cleanup notification after a turn that used Computer Use. */
    cleanupOnTurnEnd?: boolean;
    /** Deadline for the one-shot turn-ended notifier. */
    cleanupTimeoutMs?: number;
    /** Process-tree termination grace for the one-shot turn-ended notifier. */
    cleanupGraceMs?: number;
}
/** Loader schema for the Computer Use integration. */
export declare const Config: z<Config>;
/**
 * Resolve the package-relative path for the native runtime selected by Node's
 * platform and architecture names.
 */
export declare function bundledRuntimeRelativePath(platform: NodeJS.Platform, arch: string): string;
/** Resolve and validate the native runtime shipped inside this plugin package. */
export declare function resolveBundledRuntimeExecutable(packageRoot: string, platform?: NodeJS.Platform, arch?: string): string;
/**
 * Resolve how the native runtime should be launched for MCP and turn cleanup.
 * @param config - plugin config carrying an optional absolute development binary path.
 * @param bundledRuntimeExecutable - package-local native binary used when no local override is configured.
 * @returns command, mcp args, and turn-ended argv for the chosen runtime shape.
 */
export declare function resolveRuntimeLaunch(config: Pick<Config, 'runtimeExecutable'>, bundledRuntimeExecutable: string): {
    command: string;
    args: string[];
    turnEndedArgv: string[];
};
/**
 * Resolve the native runtime environment from plugin config. Explicit config
 * flags win over any same-name entries supplied through `env`.
 * @param config - plugin config carrying explicit env plus high-level runtime switches.
 * @returns env object suitable for both MCP launch and one-shot cleanup helpers.
 */
export declare function resolveRuntimeEnv(config: Pick<Config, 'env' | 'interactionMode' | 'allowAppLaunch' | 'visualIndicator'>): Record<string, string>;
/** Model guidance for semantic-first, observable desktop operation. */
export declare const COMPUTER_USE_PROMPT: string;
/**
 * Whether one public tool name belongs to this plugin's MCP namespace.
 * @param toolName - public name registered in the DSH tool registry.
 * @returns true for names owned by the fixed Computer Use MCP server namespace.
 */
export declare function isComputerUseTool(toolName: string): boolean;
/** Classify a Computer Use call from its required semantic action declaration. */
export declare function classifyComputerUseAction(toolName: string, args: unknown): ComputerUseActionRisk;
/**
 * Launch one native MCP process and expose its tools in the current Cordis
 * scope. Mount this plugin in an Agent Preset so process state, element indexes,
 * action approvals, and teardown are isolated and leased to one active Agent turn.
 * @param ctx - plugin context carrying tool, prompt, subprocess, and optional approval services.
 * @param config - desktop access, process, timeout, and cleanup policy.
 * @returns startup readiness after MCP launch and initial tool discovery.
 */
export declare function apply(ctx: Context, config: Config): Promise<void>;
