variable "location" {
  description = "The Azure region to create things in."
  type        = string
}

variable "locationShort" {
  description = "The Azure region short name."
  type        = string
}

variable "environmentShort" {
  description = "The environment (short name) to use for the deploy"
  type        = string
}

variable "commonName" {
  description = "The commonName to use for the deploy"
  type        = string
}

variable "sqlConfig" {
  description = "The SQL Configuration"
  type = object({
    version                          = string
    edition                          = string
    requested_service_objective_name = string
  })
}
