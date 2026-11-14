import { describe, expect, it } from 'vitest'
import {
  createDefaultProxyForm,
  createDefaultVisitorForm,
} from '../src/types/proxy-form'
import {
  formToStoreProxy,
  formToStoreVisitor,
  storeProxyToForm,
  storeVisitorToForm,
} from '../src/types/proxy-converters'
import type { VisitorDefinition } from '../src/types/proxy-store'

describe('proxy converters', () => {
  it('serializes only configured proxy fields into the typed store block', () => {
    const form = createDefaultProxyForm()
    Object.assign(form, {
      name: 'web',
      type: 'http',
      enabled: false,
      localIP: '10.0.0.8',
      localPort: 8080,
      useEncryption: true,
      customDomains: ['example.com', ''],
      locations: ['/api', ''],
      metadatas: [{ key: 'team', value: 'edge' }],
    })

    expect(formToStoreProxy(form)).toEqual({
      name: 'web',
      type: 'http',
      http: {
        enabled: false,
        localIP: '10.0.0.8',
        localPort: 8080,
        transport: { useEncryption: true },
        metadatas: { team: 'edge' },
        customDomains: ['example.com'],
        locations: ['/api'],
      },
    })
  })

  it('round-trips store values while applying form defaults', () => {
    const form = storeProxyToForm({
      name: 'tcp-proxy',
      type: 'tcp',
      tcp: {
        localPort: 9000,
        customDomains: 'unused-for-tcp',
        enabled: false,
        metadatas: { owner: 'platform' },
      },
    })

    expect(form).toMatchObject({
      name: 'tcp-proxy',
      type: 'tcp',
      enabled: false,
      localIP: '127.0.0.1',
      localPort: 9000,
      metadatas: [{ key: 'owner', value: 'platform' }],
      multiplexer: 'httpconnect',
    })
  })

  it.each(['stcp', 'xtcp'] as const)(
    'serializes virtual_net for %s visitors',
    (type) => {
      const form = createDefaultVisitorForm()
      Object.assign(form, {
        name: 'visitor',
        type,
        pluginType: 'virtual_net',
        pluginDestinationIP: ' 192.0.2.10 ',
        bindPort: 6000,
      })

      expect(formToStoreVisitor(form)[type]).toMatchObject({
        plugin: { type: 'virtual_net', destinationIP: '192.0.2.10' },
        bindPort: 6000,
      })
    },
  )

  it('does not serialize virtual_net for SUDP visitors', () => {
    const form = createDefaultVisitorForm()
    Object.assign(form, {
      name: 'visitor',
      type: 'sudp',
      pluginType: 'virtual_net',
      pluginDestinationIP: '192.0.2.10',
      bindPort: 6000,
    })

    expect(formToStoreVisitor(form).sudp).toEqual({ bindPort: 6000 })
  })

  it.each(['stcp', 'xtcp', 'sudp'] as const)(
    'preserves the SOCKS5 listener when editing unrelated %s visitor fields',
    (type) => {
      const plugin = {
        type: 'socks5_udp',
        bindAddr: '::1',
        bindPort: 1081,
        ...(type !== 'sudp' ? { udpVisitorAddr: '[::1]:1235' } : {}),
        futureOption: { enabled: true },
      }
      const config: VisitorDefinition = {
        name: 'socks',
        type,
        [type]: {
          serverName: 'remote-socks',
          secretKey: 'shared-key',
          bindPort: -1,
          plugin,
          transport: { useEncryption: true, futureOption: 'keep' },
          futureField: ['keep'],
        },
      }
      const before = JSON.stringify(config)
      const form = storeVisitorToForm(config)
      form.enabled = false
      form.useEncryption = false
      form.serverName = 'renamed-remote'

      const updated = formToStoreVisitor(form)
      expect(updated[type]).toEqual({
        enabled: false,
        serverName: 'renamed-remote',
        secretKey: 'shared-key',
        bindPort: -1,
        plugin,
        transport: { futureOption: 'keep' },
        futureField: ['keep'],
      })
      expect(JSON.stringify(config)).toBe(before)
      expect(form.originalConfig).toEqual(config)
    },
  )

  it('updates SOCKS5 options and supports explicit removal without restoring stale fields', () => {
    const form = storeVisitorToForm({
      name: 'socks',
      type: 'stcp',
      stcp: {
        serverName: 'remote',
        bindPort: -1,
        plugin: {
          type: 'socks5_udp',
          bindAddr: '127.0.0.2',
          bindPort: 1080,
          udpVisitorAddr: '127.0.0.1:1235',
        },
      },
    })
    form.pluginBindAddr = ''
    form.pluginBindPort = 1082
    form.pluginUDPVisitorAddr = '127.0.0.1:1236'
    expect(formToStoreVisitor(form).stcp?.plugin).toEqual({
      type: 'socks5_udp',
      bindPort: 1082,
      udpVisitorAddr: '127.0.0.1:1236',
    })
    form.pluginType = ''
    form.bindPort = 1234
    expect(formToStoreVisitor(form).stcp).toEqual({
      serverName: 'remote',
      bindPort: 1234,
    })
  })

  it('preserves an unknown plugin until explicitly changed', () => {
    const plugin = { type: 'future_plugin', options: { ports: [1234] } }
    const form = storeVisitorToForm({
      name: 'future',
      type: 'stcp',
      stcp: { bindPort: -1, plugin },
    })
    form.serverName = 'new-remote'
    expect(formToStoreVisitor(form).stcp?.plugin).toEqual(plugin)
    form.pluginType = 'virtual_net'
    form.pluginDestinationIP = '10.0.0.1'
    expect(formToStoreVisitor(form).stcp?.plugin).toEqual({
      type: 'virtual_net',
      destinationIP: '10.0.0.1',
    })
  })

  it('clears edited XTCP settings while retaining unexposed NAT options', () => {
    const form = storeVisitorToForm({
      name: 'visitor',
      type: 'xtcp',
      xtcp: {
        bindPort: -1,
        protocol: 'kcp',
        keepTunnelOpen: true,
        fallbackTo: 'backup',
        natTraversal: { disableAssistedAddrs: true, futureOption: 'keep' },
      },
    })
    form.protocol = 'quic'
    form.keepTunnelOpen = false
    form.fallbackTo = ''
    form.natTraversalDisableAssistedAddrs = false
    expect(formToStoreVisitor(form).xtcp).toEqual({
      bindPort: -1,
      natTraversal: { futureOption: 'keep' },
    })
  })
})
