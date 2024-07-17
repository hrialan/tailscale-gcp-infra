
provider "google" {
  project = var.project
}

variable "project" {
  description = "The GCP project ID"
  type        = string
}

variable "auth_key" {
  description = "Tailscale auth key"
  type        = string
  sensitive   = true
}

variable "vm_configs" {
  description = "Configuration for VMs in different countries"
  type = map(object({
    region       = string
    zone         = string
    machine_type = string
    cidr         = string
  }))
  default = {
    paris = {
      region       = "europe-west9"
      zone         = "europe-west9-a"
      machine_type = "e2-medium"
      cidr         = "10.0.1.0/24"
    }
    netherlands = {
      region       = "europe-west4"
      zone         = "europe-west4-a"
      machine_type = "e2-small"
      cidr         = "10.0.2.0/24"
    }
  }
}

# Create VPC network
resource "google_compute_network" "vpc_network" {
  name                    = "tailscale-network"
  auto_create_subnetworks = false
}

# Create subnetworks for each region
resource "google_compute_subnetwork" "subnetwork" {
  for_each      = var.vm_configs
  name          = "tailscale-subnetwork-${each.key}"
  ip_cidr_range = each.value.cidr
  network       = google_compute_network.vpc_network.self_link
  region        = each.value.region
}

# Create a dedicated service account for Tailscale VMs
resource "google_service_account" "tailscale_service_account" {
  account_id   = "tailscale-vm-sa"
  display_name = "Tailscale VM Service Account"
}

# Create compute instances
resource "google_compute_instance" "tailscale_instance" {
  for_each       = var.vm_configs
  name           = "tailscale-vm-${each.key}"
  machine_type   = each.value.machine_type
  zone           = each.value.zone
  can_ip_forward = true

  boot_disk {
    initialize_params {
      image = "debian-cloud/debian-12"
    }
  }

  network_interface {
    network    = google_compute_network.vpc_network.self_link
    subnetwork = google_compute_subnetwork.subnetwork[each.key].self_link

    access_config {
      # No need to specify nat_ip, GCP will assign an ephemeral IP
    }
  }

  tags = ["tailscale"]

  service_account {
    email  = google_service_account.tailscale_service_account.email
    scopes = ["https://www.googleapis.com/auth/compute.readonly"]
  }

  metadata_startup_script = <<-EOT
    #!/bin/bash
    LOGFILE="/var/log/startup-script.log"
    exec > >(tee -a $LOGFILE) 2>&1

    # Update package list and install necessary packages
    apt-get update
    apt-get install -y curl
    if [ $? -ne 0 ]; then
      echo "Failed to install curl" >&2
      exit 1
    fi

    # Install Tailscale
    curl -fsSL https://tailscale.com/install.sh | sh
    if [ $? -ne 0 ]; then
      echo "Failed to install Tailscale" >&2
      exit 1
    fi

    # Enable port forwarding
    echo 'net.ipv4.ip_forward = 1' | sudo tee -a /etc/sysctl.conf
    echo 'net.ipv6.conf.all.forwarding = 1' | sudo tee -a /etc/sysctl.conf
    sudo sysctl -p /etc/sysctl.conf

    # Authenticate and set up as exit node with tag
    tailscale up --authkey=${var.auth_key} --advertise-exit-node --hostname=${each.key} --tag=tag:exit-node-gcp
    if [ $? -ne 0 ]; then
      echo "Failed to set up Tailscale" >&2
      exit 1
    fi
  EOT
}

# Create firewall rule for SSH
resource "google_compute_firewall" "ssh_firewall" {
  name    = "allow-ssh"
  network = google_compute_network.vpc_network.self_link

  allow {
    protocol = "tcp"
    ports    = ["22"]
  }

  source_ranges = ["0.0.0.0/0"]
  target_tags   = ["tailscale"]
}
