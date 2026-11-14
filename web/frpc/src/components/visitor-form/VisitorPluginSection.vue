<template>
  <ConfigSection title="Plugin" :readonly="readonly">
    <div class="field-row two-col">
      <ConfigField
        label="Plugin Type"
        type="select"
        v-model="form.pluginType"
        :options="pluginOptions"
        placeholder="None"
        :readonly="readonly"
      />
      <ConfigField
        v-if="form.pluginType === 'virtual_net'"
        label="Destination IP"
        type="text"
        v-model="form.pluginDestinationIP"
        prop="pluginDestinationIP"
        placeholder="10.10.10.10"
        tip="Destination address in the frp virtual network."
        :readonly="readonly"
      />
    </div>
    <template v-if="form.pluginType === 'socks5_udp'">
      <div class="field-row two-col">
        <ConfigField label="SOCKS5 Bind Address" type="text" v-model="form.pluginBindAddr"
          placeholder="127.0.0.1" tip="IP address for the local SOCKS5 listener."
          :readonly="readonly" />
        <ConfigField label="SOCKS5 Bind Port" type="number" v-model="form.pluginBindPort"
          prop="pluginBindPort" :max="65535" :readonly="readonly" />
      </div>
      <ConfigField v-if="form.type === 'stcp' || form.type === 'xtcp'"
        label="UDP Visitor Address" type="text" v-model="form.pluginUDPVisitorAddr"
        prop="pluginUDPVisitorAddr" placeholder="127.0.0.1:1235"
        tip="Loopback address and port of the paired SUDP/XUDP visitor."
        :readonly="readonly" />
      <p class="plugin-note">SOCKS5 authentication is configured on the proxy side.</p>
      <p v-if="form.type === 'sudp'" class="plugin-note">
        The remote SUDP proxy must use socks5_udp with sessionMode = datagram and the same secret key.
      </p>
    </template>
    <p v-else-if="form.pluginType && form.pluginType !== 'virtual_net'" class="plugin-note">
      Options for this plugin are preserved when saving. Use the configuration file to edit them.
    </p>
  </ConfigSection>
</template>

<script setup lang="ts">
import { computed, watch } from 'vue'
import type { VisitorFormData } from '../../types'
import ConfigField from '../ConfigField.vue'
import ConfigSection from '../ConfigSection.vue'

const props = withDefaults(defineProps<{
  modelValue: VisitorFormData
  readonly?: boolean
}>(), { readonly: false })

const emit = defineEmits<{ 'update:modelValue': [value: VisitorFormData] }>()

const form = computed({
  get: () => props.modelValue,
  set: (val) => emit('update:modelValue', val),
})

const pluginOptions = computed(() => {
  const options = [{ label: 'None', value: '' }, { label: 'socks5_udp', value: 'socks5_udp' }]
  if (form.value.type === 'stcp' || form.value.type === 'xtcp') {
    options.push({ label: 'virtual_net', value: 'virtual_net' })
  }
  if (form.value.pluginType && !options.some((option) => option.value === form.value.pluginType)) {
    options.push({ label: form.value.pluginType, value: form.value.pluginType })
  }
  return options
})

watch(() => form.value.pluginType, (type, previous) => {
  if (!props.readonly && type === 'socks5_udp' && previous !== type) {
    form.value.bindPort = -1
  }
})

watch(() => form.value.type, (type) => {
  if (props.readonly || type !== 'sudp') return
  if (form.value.pluginType === 'virtual_net') form.value.pluginType = ''
  form.value.pluginUDPVisitorAddr = ''
})
</script>

<style scoped lang="scss">
@use '@/assets/css/form-layout';

.plugin-note {
  color: var(--text-secondary);
  font-size: 13px;
}
</style>
