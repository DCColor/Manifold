// Re-export the -O-compiled ScopeCompute target so the app can reach `ScopeTrace` via the
// single `import ManifoldCore` it already uses — no separate product/link needed. ScopeCompute
// is a dependency of this target (see Package.swift), so it's built and linked with the
// ManifoldCore product.
@_exported import ScopeCompute
