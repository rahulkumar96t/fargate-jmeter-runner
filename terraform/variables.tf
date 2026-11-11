variable "name" {
  description = "Prefix for every resource name. Lowercase letters, digits and hyphens."
  type        = string
  default     = "jmeter"

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{1,23}$", var.name))
    error_message = "name must start with a letter and contain 2-24 lowercase letters, digits or hyphens."
  }
}

variable "tags" {
  description = "Tags added to every resource that supports them."
  type        = map(string)
  default     = {}
}

# --- Network -----------------------------------------------------------------

variable "vpc_cidr" {
  description = "CIDR block of the load-test VPC. Must be a /16 to /20."
  type        = string
  default     = "10.80.0.0/16"

  validation {
    condition = (
      can(cidrhost(var.vpc_cidr, 0)) &&
      try(tonumber(split("/", var.vpc_cidr)[1]) >= 16 && tonumber(split("/", var.vpc_cidr)[1]) <= 20, false)
    )
    error_message = "vpc_cidr must be a valid IPv4 CIDR block between /16 and /20."
  }
}

variable "nat_enabled" {
  description = <<-EOT
    Create the NAT gateway. Set to false between test campaigns to stop the hourly NAT
    charge. The Elastic IP is kept either way, so the egress address that the target
    environment allow-lists never changes.
  EOT
  type        = bool
  default     = true
}

variable "allowed_egress_ports" {
  description = "TCP ports the injectors may connect to (on any address that the DNS firewall lets them resolve)."
  type        = list(number)
  default     = [80, 443]

  validation {
    condition = length(var.allowed_egress_ports) > 0 && alltrue([
      for p in var.allowed_egress_ports : p >= 1 && p <= 65535 && floor(p) == p
    ])
    error_message = "allowed_egress_ports must be a non-empty list of TCP ports (1-65535)."
  }
}

# --- DNS firewall ------------------------------------------------------------

variable "target_domains" {
  description = <<-EOT
    Domains the injectors are allowed to resolve, for example
    ["perf.example.com", "*.perf.example.com"]. A leading "*." matches subdomains only,
    so list the apex separately. Every other name, apart from the AWS endpoints the
    tasks need, gets NXDOMAIN from the Route 53 Resolver DNS Firewall.
  EOT
  type        = list(string)

  validation {
    condition = length(var.target_domains) > 0 && alltrue([
      for d in var.target_domains :
      can(regex("^(\\*\\.)?([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\\.)+[a-z][a-z0-9-]{0,61}[a-z0-9]$", d))
    ])
    error_message = "target_domains must be a non-empty list of lowercase domain names with at least two labels (an optional leading \"*.\" is allowed; \"*\" or \"*.com\" are rejected)."
  }
}

variable "extra_allowed_domains" {
  description = "Additional domains to allow, for example a third-party identity provider the test plan logs in through."
  type        = list(string)
  default     = []

  validation {
    condition = alltrue([
      for d in var.extra_allowed_domains :
      can(regex("^(\\*\\.)?([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\\.)+[a-z][a-z0-9-]{0,61}[a-z0-9]$", d))
    ])
    error_message = "extra_allowed_domains entries must be lowercase domain names with at least two labels."
  }
}

# --- Injectors ---------------------------------------------------------------

variable "injector_sizes" {
  description = <<-EOT
    Fargate CPU units and memory (MiB) for each injector size. Every pair must be a valid
    Fargate combination. The default gives JMeter 4 GiB per vCPU, because heap runs out
    before CPU does in most HTTP plans.
  EOT
  type = map(object({
    cpu    = number
    memory = number
  }))
  default = {
    S  = { cpu = 1024, memory = 4096 }
    M  = { cpu = 2048, memory = 8192 }
    L  = { cpu = 4096, memory = 16384 }
    XL = { cpu = 8192, memory = 32768 }
  }

  validation {
    condition     = length(var.injector_sizes) == 4 && alltrue([for s in ["S", "M", "L", "XL"] : contains(keys(var.injector_sizes), s)])
    error_message = "injector_sizes must define exactly the sizes S, M, L and XL."
  }

  validation {
    # Fargate CPU/memory table for Linux tasks (platform version 1.4.0).
    condition = alltrue([
      for s in values(var.injector_sizes) : (
        s.cpu == 256 ? contains([512, 1024, 2048], s.memory) :
        s.cpu == 512 ? s.memory >= 1024 && s.memory <= 4096 && s.memory % 1024 == 0 :
        s.cpu == 1024 ? s.memory >= 2048 && s.memory <= 8192 && s.memory % 1024 == 0 :
        s.cpu == 2048 ? s.memory >= 4096 && s.memory <= 16384 && s.memory % 1024 == 0 :
        s.cpu == 4096 ? s.memory >= 8192 && s.memory <= 30720 && s.memory % 1024 == 0 :
        s.cpu == 8192 ? s.memory >= 16384 && s.memory <= 61440 && s.memory % 4096 == 0 :
        s.cpu == 16384 ? s.memory >= 32768 && s.memory <= 122880 && s.memory % 8192 == 0 :
        false
      )
    ])
    error_message = "Every injector size must be a valid Fargate CPU/memory combination (for example 1024/2048-8192 or 8192/16384-61440 in 4096 steps)."
  }
}

variable "default_injector_size" {
  description = "Injector size used when a run does not set one. Also the size registered in the task definition."
  type        = string
  default     = "M"

  validation {
    condition     = contains(["S", "M", "L", "XL"], var.default_injector_size)
    error_message = "default_injector_size must be one of S, M, L, XL."
  }
}

variable "report_size" {
  description = "Size of the task that merges the JTL files and builds the HTML dashboard."
  type        = string
  default     = "L"

  validation {
    condition     = contains(["S", "M", "L", "XL"], var.report_size)
    error_message = "report_size must be one of S, M, L, XL."
  }
}

variable "max_injectors" {
  description = <<-EOT
    Upper bound for injectors per run. All injectors must run at the same time, and an
    inline Map state runs at most 40 iterations concurrently, so 40 is the hard ceiling.
  EOT
  type        = number
  default     = 10

  validation {
    condition     = var.max_injectors >= 1 && var.max_injectors <= 40 && floor(var.max_injectors) == var.max_injectors
    error_message = "max_injectors must be a whole number between 1 and 40 (inline Map concurrency limit)."
  }
}

variable "max_duration_seconds" {
  description = "Longest test duration a run may request."
  type        = number
  default     = 3600

  validation {
    condition     = var.max_duration_seconds >= 60 && var.max_duration_seconds <= 43200
    error_message = "max_duration_seconds must be between 60 and 43200 (12 hours)."
  }
}

variable "max_threads_per_injector" {
  description = "Most JMeter threads (virtual users) a single injector may run."
  type        = number
  default     = 1000

  validation {
    condition     = var.max_threads_per_injector >= 1 && var.max_threads_per_injector <= 10000
    error_message = "max_threads_per_injector must be between 1 and 10000."
  }
}

variable "injector_start_delay_seconds" {
  description = <<-EOT
    Injectors wait until execution start plus this many seconds before starting JMeter,
    so that tasks which took longer to provision still start in step with the others.
  EOT
  type        = number
  default     = 120

  validation {
    condition     = var.injector_start_delay_seconds >= 0 && var.injector_start_delay_seconds <= 900
    error_message = "injector_start_delay_seconds must be between 0 and 900."
  }
}

variable "default_thresholds" {
  description = "Pass/fail thresholds applied when a run does not set any, for example \"p95>800,errors>1%\". Empty means none."
  type        = string
  default     = ""

  validation {
    condition = var.default_thresholds == "" || alltrue([
      for t in split(",", var.default_thresholds) :
      can(regex("^\\s*[a-z0-9_]+\\s*(>=|<=|>|<)\\s*[0-9]+(\\.[0-9]+)?\\s*(%|ms)?\\s*$", t))
    ])
    error_message = "default_thresholds must be a comma-separated list such as \"p95>800,errors>1%\"."
  }
}

variable "image_tag" {
  description = "Tag of the JMeter image in the ECR repository (tags are immutable)."
  type        = string
  default     = "5.6.3"
}

variable "cpu_architecture" {
  description = "CPU architecture of the injector tasks. ARM64 (Graviton) is cheaper but needs an arm64 image."
  type        = string
  default     = "X86_64"

  validation {
    condition     = contains(["X86_64", "ARM64"], var.cpu_architecture)
    error_message = "cpu_architecture must be X86_64 or ARM64."
  }
}

variable "ephemeral_storage_gib" {
  description = "Task ephemeral storage. The report task holds every raw JTL plus the merged copy on this disk."
  type        = number
  default     = 50

  validation {
    condition     = var.ephemeral_storage_gib >= 21 && var.ephemeral_storage_gib <= 200
    error_message = "ephemeral_storage_gib must be between 21 and 200."
  }
}

variable "container_insights" {
  description = "Enable CloudWatch Container Insights on the cluster (adds CloudWatch cost)."
  type        = bool
  default     = false
}

# --- Storage, logs, notifications ---------------------------------------------

variable "jtl_retention_days" {
  description = "Days after which raw JTL files and injector logs (prefix jtl/) expire."
  type        = number
  default     = 14

  validation {
    condition     = var.jtl_retention_days >= 1 && floor(var.jtl_retention_days) == var.jtl_retention_days
    error_message = "jtl_retention_days must be a whole number of at least 1."
  }
}

variable "report_retention_days" {
  description = "Days after which HTML reports and summaries (prefix reports/) expire."
  type        = number
  default     = 365

  validation {
    condition     = floor(var.report_retention_days) == var.report_retention_days && var.report_retention_days >= var.jtl_retention_days
    error_message = "report_retention_days must be a whole number and at least jtl_retention_days; reports are built from the JTLs and are much smaller."
  }
}

variable "log_retention_days" {
  description = "Retention of the CloudWatch log groups."
  type        = number
  default     = 30

  validation {
    condition     = contains([1, 3, 5, 7, 14, 30, 60, 90, 120, 150, 180, 365, 400, 545, 731, 1096, 1827, 2192, 2557, 2922, 3288, 3653], var.log_retention_days)
    error_message = "log_retention_days must be a retention period CloudWatch Logs supports."
  }
}

variable "kms_key_arn" {
  description = "Optional customer managed KMS key for the bucket and the SNS topic. Null uses SSE-S3 and the AWS managed SNS key."
  type        = string
  default     = null

  validation {
    condition     = var.kms_key_arn == null || can(regex("^arn:aws[a-z-]*:kms:[a-z0-9-]+:[0-9]{12}:key/.+$", var.kms_key_arn))
    error_message = "kms_key_arn must be a KMS key ARN (arn:aws:kms:<region>:<account>:key/<id>)."
  }
}

variable "notification_emails" {
  description = "E-mail addresses subscribed to run notifications. Each address must confirm the subscription."
  type        = list(string)
  default     = []

  validation {
    condition     = alltrue([for e in var.notification_emails : can(regex("^[^@\\s]+@[^@\\s]+\\.[^@\\s]+$", e))])
    error_message = "notification_emails must contain valid e-mail addresses."
  }
}

variable "force_destroy" {
  description = "Allow terraform destroy to delete a non-empty results bucket and ECR repository."
  type        = bool
  default     = false
}
