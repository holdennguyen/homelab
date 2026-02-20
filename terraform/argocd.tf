resource "kubernetes_namespace" "argocd" {
  metadata {
    name = "argocd"
  }
}

resource "helm_release" "argocd" {
  name       = "argocd"
  namespace  = kubernetes_namespace.argocd.metadata[0].name
  repository = "https://argoproj.github.io/argo-helm"
  chart      = "argo-cd"
  version    = var.argocd_version

  # Expose argocd-server via NodePort so tailscale serve can proxy it.
  set {
    name  = "server.service.type"
    value = "NodePort"
  }
  set {
    name  = "server.service.nodePorts.http"
    value = "30080"
  }
  set {
    name  = "server.service.nodePorts.https"
    value = "30443"
  }

  # Run server without TLS so the NodePort plain-HTTP path works for tailscale serve.
  set {
    name  = "configs.params.server\\.insecure"
    value = "true"
  }

  # Reduce resource footprint for a single-node homelab.
  set {
    name  = "applicationSet.resources.requests.memory"
    value = "64Mi"
  }
  set {
    name  = "notifications.resources.requests.memory"
    value = "32Mi"
  }
  set {
    name  = "redis.resources.requests.memory"
    value = "32Mi"
  }

  # ESO adds a finalizer to every ExternalSecret it owns. ArgoCD sees this
  # finalizer as drift (it is not in git). This global customization tells
  # ArgoCD to ignore the finalizers field on all ExternalSecret resources,
  # preventing permanent OutOfSync noise across every Application that uses ESO.
  set {
    name  = "configs.cm.resource\\.customizations\\.ignoreDifferences\\.external-secrets\\.io_ExternalSecret"
    value = "jsonPointers:\n- /metadata/finalizers\n"
  }

  # OIDC SSO via Authentik — client secret stored in argocd-secret.
  set {
    name  = "configs.cm.url"
    value = "https://holdens-mac-mini.story-larch.ts.net:8443"
  }
  set {
    name  = "configs.cm.oidc\\.config"
    value = yamlencode({
      name      = "Authentik"
      issuer    = "https://holdens-mac-mini.story-larch.ts.net/application/o/argocd/"
      clientID  = "argocd"
      clientSecret = "$oidc.argocd.clientSecret"
      requestedScopes = ["openid", "profile", "email"]
    })
  }
  set_sensitive {
    name  = "configs.secret.extra.oidc\\.argocd\\.clientSecret"
    value = var.argocd_oidc_client_secret
  }

  # Hide the local admin login form — force SSO via Authentik.
  set {
    name  = "configs.params.server\\.dex\\.server"
    value = ""
  }
  set {
    name  = "configs.cm.admin\\.enabled"
    value = "false"
  }

  # Grant all SSO-authenticated users admin access (single-user homelab).
  set {
    name  = "configs.rbac.policy\\.default"
    value = "role:admin"
  }

  depends_on = [kubernetes_namespace.argocd]
}

# ── Infisical Application CR ──────────────────────────────────────────────────
# The Infisical Application is managed by Terraform (not by the App of Apps kustomization)
# because its Helm values include sensitive credentials (postgres/redis passwords) that
# cannot be stored in git. The Application spec's helm.values contains them directly,
# sourced from tfvars which are gitignored.

locals {
  infisical_app_yaml = yamlencode({
    apiVersion = "argoproj.io/v1alpha1"
    kind       = "Application"
    metadata = {
      name      = "infisical"
      namespace = "argocd"
      labels = {
        "app.kubernetes.io/name"       = "infisical"
        "app.kubernetes.io/part-of"    = "homelab"
        "app.kubernetes.io/component"  = "secrets"
        "app.kubernetes.io/managed-by" = "argocd"
      }
      annotations = {
        "argocd.argoproj.io/sync-wave" = "0"
      }
    }
    spec = {
      project = "secrets"
      source = {
        repoURL        = "https://dl.cloudsmith.io/public/infisical/helm-charts/helm/charts/"
        chart          = "infisical-standalone"
        targetRevision = "1.7.2"
        helm = {
          valuesObject = {
            infisical = {
              replicaCount  = 1
              kubeSecretRef = "infisical-secrets"
              service = {
                type     = "NodePort"
                nodePort = "30445"
              }
              resources = {
                requests = { cpu = "100m", memory = "512Mi" }
                limits   = { memory = "1500Mi" }
              }
              securityContext = {
                runAsUser    = 1000
                runAsGroup   = 1000
                runAsNonRoot = true
                fsGroup      = 1000
              }
            }
            ingress = { enabled = false }
            postgresql = {
              enabled          = true
              fullnameOverride = "postgresql"
              auth = {
                username = "infisical"
                password = var.infisical_postgres_password
                database = "infisicalDB"
              }
            }
            redis = {
              enabled          = true
              fullnameOverride = "redis"
              architecture     = "standalone"
              auth             = { password = var.infisical_redis_password }
            }
          }
        }
      }
      destination = {
        server    = "https://kubernetes.default.svc"
        namespace = "infisical"
      }
      syncPolicy = {
        automated = { prune = true, selfHeal = true }
        syncOptions = ["CreateNamespace=true"]
      }
      ignoreDifferences = [{
        group        = ""
        kind         = "Secret"
        jsonPointers = ["/data"]
      }]
    }
  })
}

resource "local_file" "infisical_app" {
  filename        = "${path.module}/.infisical-app.yaml"
  content         = local.infisical_app_yaml
  file_permission = "0600"
}

resource "null_resource" "infisical_app" {
  triggers = {
    manifest = local.infisical_app_yaml
  }

  provisioner "local-exec" {
    command = "kubectl apply --server-side --force-conflicts -f '${local_file.infisical_app.filename}'"
  }

  depends_on = [helm_release.argocd, local_file.infisical_app]
}

# ── ArgoCD repository credential ──────────────────────────────────────────────
# ArgoCD needs this to clone the private GitHub repo.
# The Secret label argocd.argoproj.io/secret-type=repository tells ArgoCD to
# treat it as a repository credential.

resource "kubernetes_secret" "argocd_repo_credential" {
  metadata {
    name      = "repo-homelab"
    namespace = kubernetes_namespace.argocd.metadata[0].name
    labels = {
      "argocd.argoproj.io/secret-type" = "repository"
    }
  }

  data = {
    type          = "git"
    url           = var.homelab_repo_url
    sshPrivateKey = var.argocd_repo_ssh_private_key
  }

  type = "Opaque"

  depends_on = [helm_release.argocd]
}

# ── Root Application (App of Apps) ─────────────────────────────────────────────
# We use null_resource + local-exec instead of kubernetes_manifest because
# kubernetes_manifest validates the schema against the live API at plan time,
# and the Application CRD is only available after the Helm release above runs.
# Writing to a local file and applying with kubectl sidesteps that ordering issue.

locals {
  argocd_root_app_yaml = yamlencode({
    apiVersion = "argoproj.io/v1alpha1"
    kind       = "Application"
    metadata = {
      name      = "argocd-apps"
      namespace = "argocd"
      labels = {
        "app.kubernetes.io/name"       = "argocd-apps"
        "app.kubernetes.io/part-of"    = "homelab"
        "app.kubernetes.io/component"  = "gitops"
        "app.kubernetes.io/managed-by" = "argocd"
      }
    }
    spec = {
      project = "default"
      source = {
        repoURL        = var.homelab_repo_url
        targetRevision = "HEAD"
        path           = "k8s/apps/argocd"
      }
      destination = {
        server    = "https://kubernetes.default.svc"
        namespace = "argocd"
      }
      syncPolicy = {
        automated = {
          prune    = true
          selfHeal = true
        }
        syncOptions = ["ServerSideApply=true"]
      }
    }
  })
}

# Rendered to a local file so kubectl can read it cleanly (avoids shell quoting issues).
resource "local_file" "argocd_root_app" {
  filename        = "${path.module}/.argocd-root-app.yaml"
  content         = local.argocd_root_app_yaml
  file_permission = "0600"
}

resource "null_resource" "argocd_root_app" {
  triggers = {
    manifest = local.argocd_root_app_yaml
  }

  provisioner "local-exec" {
    command = "kubectl apply --server-side -f '${local_file.argocd_root_app.filename}'"
  }

  depends_on = [helm_release.argocd, local_file.argocd_root_app]
}
