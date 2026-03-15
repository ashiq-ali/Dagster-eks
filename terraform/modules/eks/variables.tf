variable "project" {
  type = string
}

variable "environment" {
  type = string
}

variable "cluster_name" {
  type = string
}

variable "cluster_version" {
  type = string
}

variable "vpc_id" {
  type = string
}

variable "private_subnet_ids" {
  type = list(string)
}

variable "public_subnet_ids" {
  type = list(string)
}

variable "system_node_instance_types" {
  type = list(string)
}

variable "system_node_desired" {
  type = number
}

variable "system_node_min" {
  type = number
}

variable "system_node_max" {
  type = number
}

variable "worker_node_instance_types" {
  type = list(string)
}

variable "worker_node_desired" {
  type = number
}

variable "worker_node_min" {
  type = number
}

variable "worker_node_max" {
  type = number
}

variable "aws_region" {
  type = string
}
