/// Gives the Audit target a source file from the first commit. Nothing references it,
/// so a later milestone may delete it once the module has real sources.
public enum AuditModule {
    public static let name = "Audit"
}
