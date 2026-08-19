//go:build !xudp_pmtud_experiment

package transport

// experimentalPathMTUDiscoveryDefault keeps PMTUD disabled in production.
// The experiment build tag is intentionally separate from user configuration.
const experimentalPathMTUDiscoveryDefault = false
