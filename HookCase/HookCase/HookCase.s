/* The MIT License (MIT)
 *
 * Copyright (c) 2017 Steven Michaud
 *
 * Permission is hereby granted, free of charge, to any person obtaining a copy
 * of this software and associated documentation files (the "Software"), to deal
 * in the Software without restriction, including without limitation the rights
 * to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
 * copies of the Software, and to permit persons to whom the Software is
 * furnished to do so, subject to the following conditions:
 *
 * The above copyright notice and this permission notice shall be included in all
 * copies or substantial portions of the Software.
 *
 * THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
 * IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
 * FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
 * AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
 * LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
 * OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
 * SOFTWARE.
 */

/* This file mostly contains support for HookCase.kext's use of software
 * interrupts, including the raw handlers for interrupts 0x20, 0x21 and 0x22.
 * This is modeled to some extent on code in the xnu kernel's
 * osfmk/x86_64/idt64.s, but is much simpler (since that code also supports
 * hardware interrupts and syscalls).  In both user mode and kernel mode, we
 * treat our software interrupts more like syscalls than like interrupts.  So,
 * for example, we don't change %gs:CPU_PREEMPTION_LEVEL or
 * %gs:CPU_INTERRUPT_LEVEL.
 *
 * There are also miscellaneous methods, callable from C/C++ code, that needed
 * to be written in assembler.
 */

#define ALIGN 4,0x90
#include <i386/asm.h>
#include "HookCase.h"

/* These definitions are generated from genassym.c.  See it for more
 * information.
 */

/* Offsets of x86_saved_state32 fields in x86_saved_state_t */
#define R32_CS                76
#define R32_SS                88
#define R32_DS                28
#define R32_ES                24
#define R32_FS                20
#define R32_GS                16
#define R32_UESP              84
#define R32_EBP               40
#define R32_EAX               60
#define R32_EBX               48
#define R32_ECX               56
#define R32_EDX               52
#define R32_ESI               36
#define R32_EDI               32
#define R32_TRAPNO            64
#define R32_CPU               66
#define R32_ERR               68
#define R32_EFLAGS            80
#define R32_EIP               72
#define R32_CR2               44

#define ISS32_SIZE            76

/* Offsets of x86_saved_state64 fields in x86_saved_state_t */
#define R64_FS                148
#define R64_GS                144
#define R64_R8                48
#define R64_R9                56
#define R64_R10               40
#define R64_R11               104
#define R64_R12               96
#define R64_R13               88
#define R64_R14               80
#define R64_R15               72
#define R64_RBP               112
#define R64_RAX               136
#define R64_RBX               120
#define R64_RCX               128
#define R64_RDX               32
#define R64_RSI               24
#define R64_RDI               16
#define R64_CS                192
#define R64_SS                216
#define R64_RSP               208
#define R64_TRAPNO            160
#define R64_CPU               162
#define R64_TRAPFN            168
#define R64_ERR               176
#define R64_RFLAGS            200
#define R64_RIP               184
#define R64_CR2               64

#define ISS64_OFFSET          160
#define ISS64_SIZE            208

/* Offsets of x86_64_intr_stack_frame fields in x86_64_intr_stack_frame */
#define ISF64_TRAPNO          0
#define ISF64_CPU             2
#define ISF64_TRAPFN          8
#define ISF64_ERR             16
#define ISF64_RIP             24
#define ISF64_CS              32
#define ISF64_RFLAGS          40
#define ISF64_RSP             48
#define ISF64_SS              56

#define ISF64_SIZE            64

#define SS_FLAVOR             0
#define SS_32                 14
#define SS_64                 15

/* Offsets of cpu_data_fake_t fields in cpu_data_fake_t */
#define CPU_PREEMPTION_LEVEL   24
#define CPU_NUMBER             28
#define CPU_INT_STATE          32
#define CPU_ACTIVE_STACK       40
#define CPU_KERNEL_STACK       48
#define CPU_INT_STACK_TOP      56
#define CPU_INTERRUPT_LEVEL    64
#define CPU_ACTIVE_CR3         256
#define CPU_TLB_INVALID        264
#define CPU_TLB_INVALID_LOCAL  264
#define CPU_TLB_INVALID_GLOBAL 266
#define CPU_TASK_MAP           268
#define CPU_TASK_CR3           272
#define CPU_KERNEL_CR3         280

/* On getting an interrupt, the Intel processor first ORs RSP with
 * 0xFFFFFFFFFFFFFFF0, to make it 16-byte aligned.  Then it pushes the
 * following registers onto the (current) stack (user or kernel):
 *
 * SS
 * RSP
 * RFLAGS
 * CS
 * RIP
 *
 * Because the processor may have re-aligned RSP, we can't just add members
 * to the x86_64_intr_stack_frame structure (past SS) to get at what RSP
 * originally pointed to.  Instead we should dereference the value of RSP
 * from that structure.  That's actually the original value -- *not* what
 * you'd expect if the processor used "push %rsp" and so forth (which it
 * apparently doesn't).
 */

/* Called first thing on entering a raw interrupt handler.  "lea blah(%rip)"
 * uses "RIP-relative addressing".  Called with the interrupt flag cleared.
 * The original value of IF is restored (along with all the other flags in
 * the flags register) by calling IRET.
 */
#define SETUP(trapno)                                                        \
   pushq   $0             /* err */                                         ;\
   sub     $8, %rsp                                                         ;\
   push    %rax                                                             ;\
   lea     EXT(user_trampoline)(%rip), %rax                                 ;\
   mov     %rax, 8(%rsp)  /* trapfn */                                      ;\
   pop     %rax                                                             ;\
   pushq   $(trapno)      /* trapno, cpu, pad */                            ;\
   jmp     EXT(setup_continues)

Entry(setup_continues)
   /* Jump to kernel_trampoline if we have a kernel interrupt, after setting
    * up an x86_saved_state_t structure on the stack and saving the 64-bit
    * registers.  We don't do any of the other fancy state saving and
    * restoring that we do with user interrupts.  That's not needed, because
    * we user kernel interrupts like function calls -- so we don't need to
    * restore the "caller's" state in every particular.  We also, of course,
    * aren't changing privilege levels.
    */
   cmpl    $(KERNEL64_CS), ISF64_CS(%rsp)
   jne     1f

   sub     $(ISS64_OFFSET), %rsp
   mov     %r15, R64_R15(%rsp)
   mov     %rsp, %r15
   movl    $(SS_64), SS_FLAVOR(%r15)
   mov     %rax, R64_RAX(%r15)
   mov     %rbx, R64_RBX(%r15)
   mov     %rcx, R64_RCX(%r15)
   mov     %rdx, R64_RDX(%r15)
   mov     %rbp, R64_RBP(%r15)
   mov     %rdi, R64_RDI(%r15)
   mov     %rsi, R64_RSI(%r15)
   mov     %r8,  R64_R8(%r15)
   mov     %r9,  R64_R9(%r15)
   mov     %r10, R64_R10(%r15)
   mov     %r11, R64_R11(%r15)
   mov     %r12, R64_R12(%r15)
   mov     %r13, R64_R13(%r15)
   mov     %r14, R64_R14(%r15)
   mov     %cr2, %rax            /* CR2 is only useful for page faults, */
   mov     %rax, R64_CR2(%r15)   /* but save it anyway. */
   mov     %fs,  R64_FS(%r15)    /* These segment registers don't need to */
   mov     %gs,  %rax            /* be saved, but for completeness ... */
   mov     %eax, R64_GS(%r15)

   lea     EXT(kernel_trampoline)(%rip), %rax
   mov     %rax, R64_TRAPFN(%r15)
   mov     %gs:CPU_NUMBER, %ax
   mov     %ax, R64_CPU(%r15)
   jmp     EXT(kernel_trampoline)

   /* Swap the GS register's current value with the value contained in the
    * IA32_KERNEL_GS_BASE MSR (machine-specific register) address.  This makes
    * GS point to the 'cpu_data' structure (as defined in the xnu kernel's
    * osfmk/i386/cpu_data.h).  We'll switch back before returning.  (In user
    * space, GS is normally used for thread-local storage.)
    */
1: swapgs
   push    %rax
   mov     %gs:CPU_NUMBER, %ax
   mov     %ax, ISF64_CPU+8(%rsp)
   pop     %rax

   /* Make room on the stack for the rest of the interrupt stack frame,
    * then fill it out with saved registers (64-bit or 32-bit).  Also switch
    * to the kernel stack.
    */
   cmpl    $(TASK_MAP_32BIT), %gs:CPU_TASK_MAP
   je      2f
 
   /* 64-bit user interrupt */
   sub     $(ISS64_OFFSET), %rsp
   mov     %r15, R64_R15(%rsp)
   mov     %rsp, %r15
   movl    $(SS_64), SS_FLAVOR(%r15)
   mov     %gs:CPU_KERNEL_STACK, %rsp /* Switch to kernel stack */

   mov     %rax, R64_RAX(%r15)
   mov     %rbx, R64_RBX(%r15)
   mov     %rcx, R64_RCX(%r15)
   mov     %rdx, R64_RDX(%r15)
   mov     %rbp, R64_RBP(%r15)
   mov     %rdi, R64_RDI(%r15)
   mov     %rsi, R64_RSI(%r15)
   mov     %r8,  R64_R8(%r15)
   mov     %r9,  R64_R9(%r15)
   mov     %r10, R64_R10(%r15)
   mov     %r11, R64_R11(%r15)
   mov     %r12, R64_R12(%r15)
   mov     %r13, R64_R13(%r15)
   mov     %r14, R64_R14(%r15)
   mov     %cr2, %rax            /* CR2 is only useful for page faults, */
   mov     %rax, R64_CR2(%r15)   /* but save it anyway. */

   mov     %fs,  R64_FS(%r15)    /* These segment registers don't need to */
   swapgs                        /* be saved, but for completeness ... */
   mov     %gs,  %rax
   mov     %eax, R64_GS(%r15)
   swapgs

   mov     R64_TRAPFN(%r15), %rdx /* RDX := trapfn for later */
   jmp     3f

   /* 32-bit user interrupt */
2: sub     $(ISS64_OFFSET), %rsp
   mov     %rsp, %r15
   movl    $(SS_32), SS_FLAVOR(%r15)
   mov     %gs:CPU_KERNEL_STACK, %rsp /* Switch to kernel stack */

   mov     %eax, R32_EAX(%r15)
   mov     %ebx, R32_EBX(%r15)
   mov     %ecx, R32_ECX(%r15)
   mov     %edx, R32_EDX(%r15)
   mov     %ebp, R32_EBP(%r15)
   mov     %esi, R32_ESI(%r15)
   mov     %edi, R32_EDI(%r15)
   mov     %cr2, %rax           /* CR2 is only useful for page faults, */
   mov     %eax, R32_CR2(%r15)  /* but save it anyway. */

   mov     %ds,  R32_DS(%r15)
   mov     %es,  R32_ES(%r15)
   mov     %fs,  R32_FS(%r15)
   swapgs
   mov     %gs,  %rax
   mov     %eax, R32_GS(%r15)
   swapgs

   /* The offset of the 'isf' element in x86_saved_state_t's 'ss_64' is larger
    * than the whole of 'ss_32'.  So its contents won't get overwritten by
    * what we write to 'ss_32' above, even though 'ss_32' and 'ss_64' are a
    * union.
    */
   mov     R64_RIP(%r15), %eax
   mov     %eax, R32_EIP(%r15)
   mov     R64_RFLAGS(%r15), %eax
   mov     %eax, R32_EFLAGS(%r15)
   mov     R64_RSP(%r15), %eax
   mov     %eax, R32_UESP(%r15)
   mov     R64_SS(%r15), %eax
   mov     %eax, R32_SS(%r15)
   mov     R64_CS(%r15), %eax
   mov     %eax, R32_CS(%r15)
   mov     R64_TRAPNO(%r15), %ax
   mov     %ax, R32_TRAPNO(%r15)
   mov     R64_CPU(%r15), %ax
   mov     %ax, R32_CPU(%r15)
   mov     R64_ERR(%r15), %eax
   mov     %eax, R32_ERR(%r15)
   mov     R64_TRAPFN(%r15), %rdx  /* RDX := trapfn for later */

   /* Misc additional setup */
3: cld
   xor     %rbp, %rbp

   mov     %gs:CPU_KERNEL_CR3, %rcx
   mov     %rcx, %gs:CPU_ACTIVE_CR3
   /* Set kernel's CR3 if no_shared_cr3 is true */
   cmpq    $0, EXT(g_no_shared_cr3_ptr)(%rip)
   jle     4f
   lea     EXT(g_no_shared_cr3_ptr)(%rip), %rax
   cmpl    $0, (%rax)
   je      4f
   mov     %rcx, %cr3
   jmp     6f
   /* If the kernel and user-space share the same CR3, we need to check if the
    * kernel's memory mapping has changed since the kernel was last entered.
    */
4: mov     %gs:CPU_TLB_INVALID, %ecx
   test    %ecx, %ecx     /* Invalid either globally or locally? */
   jz      6f
   shr     $16, %ecx
   test    $1, %ecx       /* Invalid globally? */
   jz      5f
   /* If invalid globally, play games with CR4_PGE */
   movl    $0, %gs:CPU_TLB_INVALID
   mov     %cr4, %rcx
   and     $(~CR4_PGE), %rcx
   mov     %rcx, %cr4
   or      $(CR4_PGE), %rcx
   mov     %rcx, %cr4
   jmp     6f
   /* If only invalid locally, just reset CR3 to the same value */
5: movb    $0, %gs:CPU_TLB_INVALID_LOCAL
   mov     %cr3, %rcx
   mov     %rcx, %cr3

   /* Clear EFLAGS.AC if SMAP is present/enabled */
6: cmpq    $0, EXT(g_pmap_smap_enabled_ptr)(%rip)
   jle     7f
   lea     EXT(g_pmap_smap_enabled_ptr)(%rip), %rax
   cmpl    $0, (%rax)
   je      7f
   clac

   /* Set the Task Switch bit in CR0 to keep floating point happy */
7: mov     %cr0, %rax
   or      $(CR0_TS), %eax
   mov     %rax, %cr0

   push    %r15
   mov     %rsp, %r15
   and     $0xFFFFFFFFFFFFFFF0, %rsp
   call    EXT(reset_iotier_override)
   mov     %r15, %rsp
   pop     %r15

   /* R15 == x86_saved_state_t */
   /* RDX == trapfn */
   jmp     *%rdx

/* R15 == x86_saved_state_t */
/* GS  == cpu_data */
Entry(teardown)
   push    %r15
   mov     %rsp, %r15
   and     $0xFFFFFFFFFFFFFFF0, %rsp
   call    EXT(reset_iotier_override)
   mov     %r15, %rsp
   pop     %r15

   /* Restore the floating point state */
   push    %r15
   mov     %rsp, %r15
   and     $0xFFFFFFFFFFFFFFF0, %rsp
   call    EXT(restore_fp)
   mov     %r15, %rsp
   pop     %r15

   /* Switch back to the user CR3, if appropriate */
   mov     %gs:CPU_TASK_CR3, %rcx
   mov     %rcx, %gs:CPU_ACTIVE_CR3
   cmpq    $0, EXT(g_no_shared_cr3_ptr)(%rip)
   jle     1f
   lea     EXT(g_no_shared_cr3_ptr)(%rip), %rax
   cmpl    $0, (%rax)
   je      1f
   mov     %rcx, %cr3

1: cmpl    $(SS_32), SS_FLAVOR(%r15)
   je      2f

   /* Return from 64-bit user interrupt */
   /* Segment registers don't need restoring */
   mov     R64_R14(%r15), %r14
   mov     R64_R13(%r15), %r13
   mov     R64_R12(%r15), %r12
   mov     R64_R11(%r15), %r11
   mov     R64_R10(%r15), %r10
   mov     R64_R9(%r15),  %r9
   mov     R64_R8(%r15),  %r8
   mov     R64_RSI(%r15), %rsi
   mov     R64_RDI(%r15), %rdi
   mov     R64_RBP(%r15), %rbp
   mov     R64_RDX(%r15), %rdx
   mov     R64_RCX(%r15), %rcx
   mov     R64_RBX(%r15), %rbx
   mov     R64_RAX(%r15), %rax

   /* Switch back to user stack and restore R15 */
   mov     R64_R15(%r15), %rsp
   xchg    %r15, %rsp

   swapgs

   jmp     3f

   /* Return from 32-bit user interrupt */
2: swapgs

   mov     R32_DS(%r15), %ds
   mov     R32_ES(%r15), %es
   mov     R32_FS(%r15), %fs
   mov     R32_GS(%r15), %gs

   mov     R32_EIP(%r15), %eax
   mov     %eax, R64_RIP(%r15)
   mov     R32_EFLAGS(%r15), %eax
   mov     %eax, R64_RFLAGS(%r15)
   mov     R32_CS(%r15), %eax
   mov     %eax, R64_CS(%r15)
   mov     R32_UESP(%r15), %eax
   mov     %eax, R64_RSP(%r15)
   mov     R32_SS(%r15), %eax
   mov     %eax, R64_SS(%r15)

   mov     R32_EAX(%r15), %eax
   mov     R32_EBX(%r15), %ebx
   mov     R32_ECX(%r15), %ecx
   mov     R32_EDX(%r15), %edx
   mov     R32_EBP(%r15), %ebp
   mov     R32_ESI(%r15), %esi
   mov     R32_EDI(%r15), %edi

   /* Switch back to user stack */
   mov     %r15, %rsp

   /* Restore RSP as of entry to raw interrupt handlers.  IRETQ will restore
    * it to its original value, along with RFLAGS, SS, CS and RIP (or the
    * 32-bit equivalents in that mode).
    */
3: add     $(ISS64_OFFSET)+8+8+8, %rsp

   iretq

/* Calls one of our user interrupt handlers in HookCase.cpp.  Called with:
 *   R15 == x86_saved_state_t
 *   GS  == cpu_data
 *   RSP == kernel stack
 */
Entry(user_trampoline)
   mov     R64_TRAPNO(%r15), %cx
   cmpw    $(0x20), %cx
   jne     1f
   lea     EXT(handle_user_0x20_intr)(%rip), %rax
   jmp     4f
1: cmpw    $(0x21), %cx
   jne     2f
   lea     EXT(handle_user_0x21_intr)(%rip), %rax
   jmp     4f
2: cmpw    $(0x22), %cx
   jne     3f
   lea     EXT(handle_user_0x22_intr)(%rip), %rax
   jmp     4f
3: cmpw    $(0x23), %cx
   jne     5f
   lea     EXT(handle_user_0x23_intr)(%rip), %rax

4: mov     %r15, %rdi
   mov     %gs, %rsi

   push    %r15
   sti
   mov     %rsp, %r15                /* Apparently the Apple ABI requires */
   and     $0xFFFFFFFFFFFFFFF0, %rsp /* a 16-byte aligned stack on calls. */
   call    *%rax
   mov     %r15, %rsp
   cli
   pop     %r15

5: jmp     EXT(teardown)

/* Calls one of our kernel interrupt handlers in HookCase.cpp.  Called with:
 *   R15 == x86_saved_state_t
 *   GS  == cpu_data
 */
Entry(kernel_trampoline)
   mov     R64_TRAPNO(%r15), %cx
   cmpw    $(0x20), %cx
   jne     1f
   lea     EXT(handle_kernel_0x20_intr)(%rip), %rax
   jmp     4f
1: cmpw    $(0x21), %cx
   jne     2f
   lea     EXT(handle_kernel_0x21_intr)(%rip), %rax
   jmp     4f
2: cmpw    $(0x22), %cx
   jne     3f
   lea     EXT(handle_kernel_0x22_intr)(%rip), %rax
   jmp     4f
3: cmpw    $(0x23), %cx
   jne     5f
   lea     EXT(handle_kernel_0x23_intr)(%rip), %rax

4: mov     %r15, %rdi
   mov     %gs, %rsi

   sti
   cld

   push    %r15
   mov     %rsp, %r15                /* Apparently the Apple ABI requires */
   and     $0xFFFFFFFFFFFFFFF0, %rsp /* a 16-byte aligned stack on calls. */
   call    *%rax
   mov     %r15, %rsp
   pop     %r15

5: jmp     EXT(kernel_teardown)

/* Called with:
 *   R15 == x86_saved_state_t
 *   GS  == cpu_data
 */
Entry(kernel_teardown)
   /* IRETQ apparently doesn't restore RSP (and SS) when returning from intra-
    * privilege-level interrupts (as we're doing here).  So if we want to
    * apply changes we may have made to RSP in the x86_64_intr_stack_frame
    * structure, we need to do it "by hand".  For this we sacrifice R10 and
    * R11.  The C/C++ ABI doesn't require these registers be preserved across
    * function calls, and we don't need them for values returned from our
    * hooks.
    */
   mov     R64_RFLAGS(%r15), %r10
   mov     R64_RIP(%r15), %r11

   mov     R64_R14(%r15), %r14
   mov     R64_R13(%r15), %r13
   mov     R64_R12(%r15), %r12
   mov     R64_R9(%r15),  %r9
   mov     R64_R8(%r15),  %r8
   mov     R64_RSI(%r15), %rsi
   mov     R64_RDI(%r15), %rdi
   mov     R64_RBP(%r15), %rbp
   mov     R64_RDX(%r15), %rdx
   mov     R64_RCX(%r15), %rcx
   mov     R64_RBX(%r15), %rbx
   mov     R64_RAX(%r15), %rax
   mov     R64_RSP(%r15), %rsp
   mov     R64_R15(%r15), %r15

   push    %r10
   popfq
   push    %r11

   retq

Entry(intr_0x20_raw_handler)
   SETUP(0x20)

Entry(intr_0x21_raw_handler)
   SETUP(0x21)

Entry(intr_0x22_raw_handler)
   SETUP(0x22)

Entry(intr_0x23_raw_handler)
   SETUP(0x23)

/* In developer and debug kernels, the OSCompareAndSwap...() all enforce a
 * requirement that 'address' be 4-byte aligned.  But this is actually only
 * needed by Intel hardware in user mode, and it's much more convenient for
 * us to be able to ignore it.  So we need "fixed" versions of these methods
 * that don't (ever) enforce this requirement.
 */

/* Boolean OSCompareAndSwap(UInt32 oldValue, UInt32 newValue,
 *                          volatile UInt32 *address);
 *
 * Called with:
 *
 *   EDI == oldValue
 *   ESI == newValue
 *   RDX == address
 */
Entry(OSCompareAndSwap_fixed)
   push    %rbp
   mov     %rsp, %rbp

   cmp     $0, %rdx
   jne     1f

   xor     %rax, %rax
   pop     %rbp
   retq

1: mov     %edi, %eax  /* EAX == oldValue */

   lock
   cmpxchg %esi, (%rdx)

   setz    %al
   pop     %rbp
   retq

/* Boolean OSCompareAndSwap64(UInt64 oldValue, UInt64 newValue,
 *                            volatile UInt64 *address);
 * Boolean OSCompareAndSwapPtr(void *oldValue, void *newValue,
 *                             void * volatile *address);
 *
 * Called with:
 *
 *   RDI == oldValue
 *   RSI == newValue
 *   RDX == address
 */
Entry(OSCompareAndSwap64_fixed)
Entry(OSCompareAndSwapPtr_fixed)
   push    %rbp
   mov     %rsp, %rbp

   cmp     $0, %rdx
   jne     1f

   xor     %rax, %rax
   pop     %rbp
   retq

1: mov     %rdi, %rax  /* RAX == oldValue */

   lock
   cmpxchg %rsi, (%rdx)

   setz    %al
   pop     %rbp
   retq

/* Boolean OSCompareAndSwap128(__uint128_t oldValue, __uint128_t newValue,
 *                             volatile __uint128_t *address);
 *
 * Called with:
 *
 *   RSI:RDI == oldValue (RSI is high qword)
 *   RCX:RDX == newValue (RCX is high qword)
 *   R8      == address
 *
 * 'address' (R8) must be 16-byte aligned.
 */
Entry(OSCompareAndSwap128)
   push    %rbp
   mov     %rsp, %rbp
   push    %rbx

   cmp     $0, %r8
   jne     1f

   xor     %rax, %rax
   pop     %rbx
   pop     %rbp
   retq

1: mov     %rdx, %rbx  /* RCX:RBX == newValue */
   mov     %rsi, %rdx
   mov     %rdi, %rax  /* RDX:RAX == oldValue */

   lock
   cmpxchg16b (%r8)

   setz    %al
   pop     %rbx
   pop     %rbp
   retq

/* CALLER is for kernel methods we've breakpointed which have a standard C/C++
 * prologue.  We can use it to skip past the breakpoint and call the
 * "original" method, without having to unset and reset the breakpoint.
 */

#define CALLER(func)                  \
   Entry(func ## _caller)            ;\
      lea     EXT(func)(%rip), %r10  ;\
      mov     (%r10), %r10           ;\
      add     $4, %r10               ;\
      push    %rbp                   ;\
      mov     %rsp, %rbp             ;\
      jmp     *%r10                  ;\

CALLER(vm_page_validate_cs)

CALLER(mac_file_check_library_validation)

CALLER(mac_file_check_mmap)

