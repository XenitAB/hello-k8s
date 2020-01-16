resource "random_password" "sqlServerPassword" {
  length           = 24
  special          = true
  override_special = "!-_="

  keepers = {
    sql_server_name = "sql-${var.environmentShort}-${var.locationShort}-${var.commonName}"
  }
}

resource "azurerm_sql_server" "sqlServer" {
  name                         = "sql-${var.environmentShort}-${var.locationShort}-${var.commonName}"
  resource_group_name          = data.azurerm_resource_group.rg.name
  location                     = data.azurerm_resource_group.rg.location
  version                      = var.sqlConfig.version
  administrator_login          = var.commonName
  administrator_login_password = random_password.sqlServerPassword.result
}

resource "azurerm_sql_database" "sqlDb" {
  name                             = "db-${var.environmentShort}-${var.locationShort}-${var.commonName}"
  resource_group_name              = data.azurerm_resource_group.rg.name
  location                         = data.azurerm_resource_group.rg.location
  server_name                      = azurerm_sql_server.sqlServer.name
  edition                          = var.sqlConfig.edition
  requested_service_objective_name = var.sqlConfig.requested_service_objective_name
}

resource "kubernetes_secret" "k8sSecretSqlCredentials" {
  metadata {
    name      = "mssql-credentials"
    namespace = var.commonName
  }

  data = {
    username = var.commonName
    password = random_password.sqlServerPassword.result
    host     = azurerm_sql_server.sqlServer.fully_qualified_domain_name
    database = "db-${var.environmentShort}-${var.locationShort}-${var.commonName}"
  }
}
