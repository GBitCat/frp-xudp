import { defineComponent } from 'vue'
import { flushPromises, mount } from '@vue/test-utils'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import ElementPlus from 'element-plus'
import VisitorEdit from '../src/views/VisitorEdit.vue'
import ConfigField from '../src/components/ConfigField.vue'
import type { VisitorDefinition } from '../src/types/proxy-store'

const mocks = vi.hoisted(() => ({
  getStoreVisitor: vi.fn(),
  updateVisitor: vi.fn(),
  push: vi.fn(),
}))

vi.mock('../src/api/frpc', () => ({ getStoreVisitor: mocks.getStoreVisitor }))
vi.mock('../src/stores/visitor', () => ({
  useVisitorStore: () => ({ updateVisitor: mocks.updateVisitor }),
}))
vi.mock('vue-router', () => ({
  useRoute: () => ({ params: { name: 'socks' } }),
  useRouter: () => ({ push: mocks.push, back: vi.fn() }),
  onBeforeRouteLeave: vi.fn(),
}))

let wrapper: ReturnType<typeof mount> | undefined

async function editVisitor(config: VisitorDefinition) {
  mocks.getStoreVisitor.mockResolvedValue(config)
  wrapper = mount(VisitorEdit, {
    global: {
      plugins: [ElementPlus],
      stubs: {
        RouterLink: defineComponent({ template: '<a><slot /></a>' }),
        ActionButton: defineComponent({
          emits: ['click'],
          template: '<button @click="$emit(\'click\')"><slot /></button>',
        }),
      },
    },
  })
  await flushPromises()
  return wrapper
}

async function updateField(label: string, value: unknown) {
  const field = wrapper!
    .findAllComponents(ConfigField)
    .find((item) => item.props('label') === label)
  expect(field, `field ${label}`).toBeDefined()
  field!.vm.$emit('update:modelValue', value)
  await flushPromises()
}

async function save() {
  await wrapper!
    .findAll('button')
    .find((button) => button.text() === 'Update')!
    .trigger('click')
  await flushPromises()
}

beforeEach(() => vi.clearAllMocks())
afterEach(() => {
  wrapper?.unmount()
  wrapper = undefined
})

describe('visitor editing', () => {
  it.each(['stcp', 'xtcp', 'sudp'] as const)(
    'saves an unrelated edit without losing the %s SOCKS5 listener',
    async (type) => {
      const plugin = {
        type: 'socks5_udp',
        bindAddr: '127.0.0.1',
        bindPort: 1081,
        ...(type !== 'sudp' ? { udpVisitorAddr: '127.0.0.1:1235' } : {}),
      }
      await editVisitor({
        name: 'socks',
        type,
        [type]: {
          serverName: 'remote',
          secretKey: 'shared-key',
          bindPort: -1,
          plugin,
        },
      })
      await updateField('Server Name', 'updated-remote')
      await save()

      expect(mocks.updateVisitor).toHaveBeenCalledWith('socks', {
        name: 'socks',
        type,
        [type]: {
          serverName: 'updated-remote',
          secretKey: 'shared-key',
          bindPort: -1,
          plugin,
        },
      })
      expect(mocks.push).toHaveBeenCalledWith('/visitors')
    },
  )

  it('keeps the SUDP port requirement when the SOCKS5 plugin is removed', async () => {
    await editVisitor({
      name: 'socks',
      type: 'sudp',
      sudp: {
        serverName: 'remote',
        secretKey: 'shared-key',
        bindPort: -1,
        plugin: { type: 'socks5_udp', bindPort: 1081 },
      },
    })
    await updateField('Plugin Type', '')
    await save()
    expect(mocks.updateVisitor).not.toHaveBeenCalled()
    await vi.waitFor(() =>
      expect(wrapper!.text()).toContain(
        'SUDP bind port must be greater than 0',
      ),
    )
    await updateField('Bind Port', 1234)
    await save()
    expect(mocks.updateVisitor).toHaveBeenCalledWith('socks', {
      name: 'socks',
      type: 'sudp',
      sudp: {
        serverName: 'remote',
        secretKey: 'shared-key',
        bindPort: 1234,
      },
    })
  })

  it('validates the standalone SOCKS5 listener and shared secret before saving', async () => {
    await editVisitor({
      name: 'socks',
      type: 'sudp',
      sudp: {
        serverName: 'remote',
        secretKey: 'shared-key',
        bindPort: -1,
        plugin: { type: 'socks5_udp', bindPort: 1081 },
      },
    })
    await updateField('SOCKS5 Bind Port', 0)
    await updateField('Secret Key', '')
    await save()
    expect(mocks.updateVisitor).not.toHaveBeenCalled()
    await vi.waitFor(() => {
      expect(wrapper!.text()).toContain(
        'SOCKS5 bind port must be an integer from 1 to 65535',
      )
      expect(wrapper!.text()).toContain(
        'Secret key is required for SOCKS5 datagram sessions',
      )
    })
  })
})
