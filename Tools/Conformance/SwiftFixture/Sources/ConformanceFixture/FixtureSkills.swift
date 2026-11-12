// SPDX-License-Identifier: Apache-2.0
// Synthetic skills for the pinned Skills-extension (SEP-2640) conformance scenarios
// (src/scenarios/server/skills); see PROVENANCE.md and retained LICENSE.
import MCPSkills

public enum FixtureSkills {
    /// A top-level skill, a prefixed skill with supporting files (text and binary) and a
    /// nested skill, so every directory level and the nesting rules are exercised.
    public static let catalog: SkillCatalog = {
        let refunds = """
        ---
        name: refunds
        description: Process customer refund requests per company policy
        license: Apache-2.0
        metadata:
          owner: billing
        ---
        # Refunds

        Use [the email template](examples/email.md) and the scripts in `scripts/`.
        """
        let disputes = "---\nname: disputes\ndescription: Handle card disputes before refunding\n---\nNested skill.\n"
        let workflow = "---\nname: git-workflow\ndescription: Follow this team's Git conventions for branching and commits\n---\nUse feature branches.\n"
        do {
            return try SkillCatalog([
                SkillSource(path: "git-workflow", files: [SkillFile(path: "SKILL.md", text: workflow)]),
                SkillSource(path: "acme/billing/refunds", files: [
                    SkillFile(path: "SKILL.md", text: refunds),
                    SkillFile(path: "examples/email.md", text: "Dear customer,\n\nYour refund is on its way.\n"),
                    SkillFile(path: "scripts/check.py", text: "print('ok')\n"),
                    SkillFile(path: "assets/logo.png", contents: [137, 80, 78, 71, 13, 10, 26, 10]),
                    SkillFile(path: "disputes/SKILL.md", text: disputes),
                ]),
                SkillSource(path: "acme/billing/refunds/disputes", files: [SkillFile(path: "SKILL.md", text: disputes)]),
            ])
        } catch { fatalError("fixture skills are invalid: \(error)") }
    }()
}
