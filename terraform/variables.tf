# Azure region. uksouth is blocked by this subscription's policy, so we use the closest allowed one
variable "location" {
  description = "Azure region for all resources."
  type        = string
  default     = "belgiumcentral"
}

# Azure region for the SQL server only, because the free SQL offer isn't available in belgiumcentral
variable "sql_location" {
  description = "Azure region for the SQL server. The database inherits this region."
  type        = string
  default     = "germanywestcentral"
}

# Your laptop's public IP, passed on the command line so it never gets saved in code
variable "my_ip_address" {
  description = "Public IPv4 address allowed through the SQL firewall."
  type        = string

  # Stop early if the value doesn't look like an IPv4 address
  validation {
    condition     = can(cidrhost("${var.my_ip_address}/32", 0))
    error_message = "my_ip_address must be an IPv4 address, for example 203.0.113.10."
  }
}

# Tags added to every resource that supports them
variable "tags" {
  description = "Tags applied to all taggable resources."
  type        = map(string)
  default = {
    project = "ukpay"
    env     = "dev"
  }
}
