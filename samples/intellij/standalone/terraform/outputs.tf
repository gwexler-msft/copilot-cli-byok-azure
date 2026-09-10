output "client_base_url" {
  description = "Point JetBrains AI Assistant here (URL field), with the APIM subscription key as the API key."
  value       = "http://${var.proxy_static_private_ip}:8080/${var.intellij_api_path}/v1"
}

output "proxy_private_ip" {
  description = "The proxy VM's static private IP."
  value       = var.proxy_static_private_ip
}

output "proxy_nic_id" {
  description = "The NIC attached to the proxy VM (customer-supplied when proxy_nic_id is set, otherwise deployment-created)."
  value       = var.proxy_nic_id == "" ? azurerm_network_interface.proxy[0].id : data.azurerm_network_interface.proxy[0].id
}

output "intellij_api_path" {
  description = "Path of the dedicated API (client base = http://<proxy-ip>:8080/<this>/v1)."
  value       = var.intellij_api_path
}
