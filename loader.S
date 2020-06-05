%include "boot.inc"

SECTION LOADER vstart=LOADER_BASE_ADDR

LOADER_STACK_TOP equ LOADER_BASE_ADDR
	
GDT_BASE: 
	dd 0x00000000
	dd 0x00000000

CODE_DESC:
	dd 0x0000ffff
	dd DESC_CODE_HIGH4

DATA_STACK_DESC:
	dd 0x0000ffff
	dd DESC_DATA_HIGH4

VIDEO_DESC:
	dd 0x80000007		;limit = (0xbffff-0xb8000) / 4k = 0x7
	dd DESC_VIDEO_HIGH4	;此时的dpl为0

GDT_SIZE equ $-GDT_BASE
GDT_LIMIT equ GDT_SIZE-1

times 60 dq 0

; (CODE_DESC-GDT_BASE)/8 + TI_GDT + RPL0
SELECTOR_CODE equ (0x0001<<3) + TI_GDT + RPL0
SELECTOR_DATA equ (0X0002<<3) + TI_GDT + RPL0
SELECTOR_VIDEO equ (0X0003<<3) + TI_GDT + RPL0

total_mem_bytes:	;0xb00 保存内存容量, 以字节为单位
	dd 0

gdt_ptr:
	dw GDT_LIMIT
	dd GDT_BASE
;loadermsg:
;	db '2 loader in real.'

ards_buf:
	times 244 db 0	;对齐:4+6+244+2=256

ards_nr:dw 0		;记录ARDS结构体数量

loader_start:
	
;获取内存布局=====================================================
	xor ebx, ebx		;设置ebx为0
	mov edx, 0x534d4150	;验证签名
	mov di, ards_buf	;ARDS缓冲区
.e820_mem_get_loop:
	mov eax, 0x0000e820		;更新eax值
	mov ecx, 20			;ARDS大小为20字节
	int 0x15
	jc .e820_failed_so_try_e801	
	add di, cx
	inc word [ards_nr]		;记录ARDS数量
	cmp ebx, 0
	jnz .e820_mem_get_loop

	;找到(base_add_low + length_low)的最大值
	mov cx, [ards_nr]
	mov ebx, ards_buf
	xor edx, edx		;edx记录最大值,先清零
.find_max_mem_area:
	mov eax, [ebx]		;base_add_low
	add eax, [ebx+8]	;length_low
	add ebx, 20
	cmp edx, eax
	jge .next_ards
	mov edx, eax
.next_ards:
	loop .find_max_mem_area
	jmp .mem_get_ok

;ax,cx以KB为单位,为低16MB, bx,dx以64KB为单位, 为16MB到4G
.e820_failed_so_try_e801:
	mov ax, 0xe801
	int 0x15
	jc .e801_failed_so_try88
	
	;先求ax部分,再求bx部分
	mov cx, 0x400		;0x400等于1024
	mul cx
	shl edx, 16
	and eax, 0x0000ffff
	or edx, eax
	add edx, 0x100000	;ax只是15MB, 所以要加1MB
	mov esi, edx		;存入esi备份

	xor eax, eax
	mov ax, bx
	mov ecx, 0x10000
	mul ecx
	
	add esi, eax
	mov edx, esi
	jmp .mem_get_ok

.e801_failed_so_try88:
	mov ah, 0x88
	int 0x15
	jc .error_hlt
	and eax, 0x0000ffff

	mov cx, 0x400		;0x400等于1024
	mul cx
	shl edx, 16
	or edx, eax
	add edx, 0x100000	;加1MB

.mem_get_ok:
	mov [total_mem_bytes], edx	

	
;打印字符串=======================================================
;	mov sp, LOADER_BASE_ADDR;
;	mov bp, loadermsg	;es:bp = 字符串地址
;	mov cx, 17		;CX: 字符串长度
;	mov ax, 0x1301		;AH: 中断功能号, AL: 显示输出方式
;	mov bx, 0x001f		;BH: 页码, BL: 属性
;	mov dx, 0x1800		;(DH:DL): 坐标(行:列)
;	int 0x10


;准备进入保护模式=================================================
	;打开A20 Gate
	in al, 0x92
	or al, 0000_0010b
	out 0x92, al
	
	;加载GDT
	lgdt [gdt_ptr]

	;修改cr0的0位置为1, 进入保护模式
	mov eax, cr0
	or eax, 0x00000001;
	mov cr0, eax

	jmp dword SELECTOR_CODE: p_mode_start	;刷新流水线
.error_hlt:
	hlt


[bits 32]
p_mode_start:
	mov ax, SELECTOR_DATA
	mov ds, ax
	mov es, ax
	mov ss, ax
	mov esp, LOADER_STACK_TOP
	mov ax, SELECTOR_VIDEO
	mov gs, ax

;加载 kernel
    	;mov eax, KERNEL_START_SECTOR
	;mov ebx, KERNEL_BIN_BASE_ADDR
	;mov ecx, 200

	;call rd_disk_m_32	

;创建页目录及页表并初始化页内存位图===================================
		
	call setup_page

	sgdt [gdt_ptr]	;备份GDT

	;更新GDT...基址
	mov ebx, [gdt_ptr + 2]
	or dword [ebx + 0x18 + 4], 0xc0000000	;3*8B = 0x18, 视频段	

	;将gdt的基址加上0xc0000000
	add dword [gdt_ptr + 2], 0xc0000000	
	add esp, 0xc0000000			;映射栈到内核

	;把页目录地址赋值给cr3
	mov eax, PAGE_DIR_TABLE_POS
	mov cr3, eax
	;打开cr0的PG位
	mov eax, cr0
	or eax, 0x80000000	
	mov cr0, eax
	
	lgdt [gdt_ptr]	;加载新GDT地址

	mov byte [gs:160], 'V'
	jmp $


; 由于在实模式下偏移地址为16位,所以用bx只会访问到0~FFFFh的偏移。
; loader的栈指针为0x900,bx为指向的数据输出缓冲区,且为16位，
; 超过0xffff后,bx部分会从0开始,所以当要读取的扇区数过大
; 待写入的地址超过bx的范围时，从硬盘上读出的数据会把0x0000~0xffff的覆盖，
; 造成栈被破坏,所以ret返回时,返回地址被破坏了,已经不是之前正确的地址,
; 故程序出会错,不知道会跑到哪里去。
; 所以改为ebx代替bx指向缓冲区,这样生成的机器码前面会有0x66和0x67来反转。
; 0X66用于反转默认的操作数大小! 0X67用于反转默认的寻址方式.
; cpu处于16位模式时,会理所当然的认为操作数和寻址都是16位,处于32位模式时,
; 也会认为要执行的指令是32位.
; 当我们在其中任意模式下用了另外模式的寻址方式或操作数大小
; (姑且认为16位模式用16位字节操作数，32位模式下用32字节的操作数)时,
; 编译器会在指令前帮我们加上0x66或0x67，临时改变当前cpu模式到另外的模式下.
; 假设当前运行在16位模式,遇到0X66时,操作数大小变为32位.
; 假设当前运行在32位模式,遇到0X66时,操作数大小变为16位.
; 假设当前运行在16位模式,遇到0X67时,寻址方式变为32位寻址
; 假设当前运行在32位模式,遇到0X67时,寻址方式变为16位寻址.


;创建页目录和页表=====================================================
setup_page:

	mov ecx, 4096
	mov esi, 0
.clear_page_dir:	;先将页目录表占用空间清0 (4KB)
	mov byte [PAGE_DIR_TABLE_POS + esi], 0
	inc esi
	loop .clear_page_dir

;创建页目录项PDE
.create_pde:
	mov eax, PAGE_DIR_TABLE_POS
	add eax, 0x1000
	mov ebx, eax
	;      0x00000000~0xbfffffff共计3G属于用户进程

	or eax, PG_US_U | PG_RW_W | PG_P
	mov [PAGE_DIR_TABLE_POS + 0x0], eax	;pde_1  指向 页表项_1
	mov [PAGE_DIR_TABLE_POS + 0xc00], eax	;pde_c00指向 页表项_1
	sub eax, 0x1000
	mov [PAGE_DIR_TABLE_POS + 4092], eax ;pde_fff指向页目录表自己

;创建页表项PTE (第一个页表)	;每个页表项4B
	mov ecx, 256		;每页大小4k, 4k*256 = 1M低端内存
	mov esi, 0
	mov edx, PG_US_U | PG_RW_W | PG_P	;指向物理地址 0
.create_pte:			;把地址写到表
	mov [ebx+esi*4], edx	;ebx = 0x101000, 分页表
	add edx, 4096		;一个内存页为4096B(4KB)
	inc esi			
	loop .create_pte

;创建内核其他页表的PDE
	mov eax, PAGE_DIR_TABLE_POS
	add eax, 0x2000		;0x0000是PDE, 0x1000是内核1M
	or eax, PG_US_U | PG_RW_W | PG_P

	mov ebx, PAGE_DIR_TABLE_POS
	mov ecx, 254
	mov esi, 769
.create_kernel_pde:		;把PDE的高位部分(指向内核)写死
	mov [ebx+esi*4], eax	;pde_c00以上的项
	inc esi
	add eax, 0x1000		;从第二个页表开始指向
	loop .create_kernel_pde

	ret
;info tab显示的是二级页表映射到PTE的起始地址和范围大小

;0x00000000-0x000fffff -> 0x000000000000-0x0000000fffff
;PDE_0 指向 1_PTE.  由1024个4B页表项组成的4KB PTE指向1MB 物理地址

;0xc0000000-0xc00fffff -> 0x000000000000-0x0000000fffff
;因为PDE_c00 也指向 1_PTE, 和PDE_0指向相同

;0xffc00000-0xffc00fff -> 0x000000101000-0x000000101fff
;指向PDE_0 的地址 ffc(1111 1111 11)指向了PDE自己 
;                 000(00 0000 0000)指向了PDE_0

;0xfff00000-0xffffefff -> 0x000000101000-0x0000001fffff
;原理同上

;0xfffff000-0xffffffff -> 0x000000100000-0x000000100fff
;指向PDE 的物理地址 fffff 分解为 1111 1111 11 和 11 1111 1111
;通过1111 1111 11找到PDE_1023,PDE_1023指向PDE自己
;再由11 1111 1111找到PDE_1023,PDE_1023指向PDE自己
;这里是因为所有的虚拟地址都要进行二级页表的两次转换,所以看起来"奇怪"
