output "argocd_url_tailscale" {
  description = "ArgoCD UI via Tailscale Serve (configure with: tailscale serve --bg --https 8443 http://localhost:30080)"
  value       = "https://holdens-mac-mini.story-larch.ts.net:8443"
}

output "argocd_nodeport_http" {
  description = "ArgoCD HTTP NodePort (local access)"
  value       = "http://localhost:30080"
}

output "argocd_admin_password_command" {
  description = "Command to retrieve the initial ArgoCD admin password"
  value       = "kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d"
}

output "infisical_url_tailscale" {
  description = "Infisical UI via Tailscale Serve (configure with: tailscale serve --bg --https 8445 http://localhost:30445)"
  value       = "https://holdens-mac-mini.story-larch.ts.net:8445"
}

output "next_steps" {
  description = "Post-apply checklist"
  value       = <<-EOT
    1. Wait for ArgoCD to sync all Applications:
         kubectl get applications -n argocd -w

    2. Once Infisical is running, open the Infisical UI and create application secrets
       in the "homelab" project under the "prod" environment.
       See docs/bootstrap.md for the full list.

    3. Create a Machine Identity in Infisical UI:
         Settings → Machine Identities → Create → Universal Auth
       Then update terraform.tfvars with the new clientId / clientSecret and re-run:
         terraform apply

    4. ESO will reconcile ExternalSecrets and create K8s Secrets.

    5. Configure Tailscale Serve (run once on the Mac mini):
         tailscale serve --bg http://localhost:30500          # Authentik
         tailscale serve --bg --https 8443 http://localhost:30080   # ArgoCD
         tailscale serve --bg --https 8444 http://localhost:30090   # Grafana
         tailscale serve --bg --https 8445 http://localhost:30445   # Infisical
         tailscale serve --bg --https 8446 http://localhost:30100   # LaunchFast
         tailscale serve --bg --https 8447 http://localhost:30789   # OpenClaw
  EOT
}
