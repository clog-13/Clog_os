%include "boot.inc"
SECTION MBR vstart=0x7c00

;打印字符串===========================================================
	mov ax, cs	;cs=0
	mov ds, ax
	mov ss, ax
	mov es, ax
	mov fs, ax
	mov sp, 0x7c00

	mov ax, 0xb800	;设置显存地址
	mov gs, ax

	;清屏，上卷全部行，则可清屏
	mov ax, 0x600	;AH: 功能号 AL: 上卷的行数
	mov bx, 0x700	;BH: 上卷行属性
	mov cx, 0	;(CL,CH): 窗口左上角的(X,Y)位置
	mov dx, 0x184f	;(DL,DH): 窗口右下角的(X,Y)位置
			;0x18=24, 0x4f=79
	
	int 0x10

	mov byte [gs:0x00], 'C'
	mov byte [gs:0x01], 0xA4
	mov byte [gs:0x02], 'L'
	mov byte [gs:0x03], 0xA4
	mov byte [gs:0x04], 'O'
	mov byte [gs:0x05], 0xA4
	mov byte [gs:0x06], '.'
	mov byte [gs:0x07], 0xA4
	mov byte [gs:0x08], 'G'
	mov byte [gs:0x09], 0xA4

	;获取光标位置
	;mov ah, 3	;AH: 功能号
	;mov bh, 0	;BH: 待获取光标的页号
	;int 0x10	

	;打印字符串
	;mov ax, msg
	;mov bp, ax	;es:bp: 为串首地址
	;mov cx, 17	;CX: 串长度
	;mov ax, 0x1301	;AL: 设置写字符方式， 0x01=光标跟随移动
	;mov bx, 0x2	;BH: 要显示的页号 BL: 字符属性
	;int 0x10

;从硬盘加载loader程序=================================================
	mov eax, LOADER_START_SECTOR	;起始扇区LBA地址: 0x2
	mov bx, LOADER_BASE_ADDR	;写入地址: 0x900
	mov cx,	4			;待写入区间数
	call rd_disk_m_16

	;jmp LOADER_BASE_ADDR		;0x900
	jmp LOADER_BASE_ADDR+0x300

rd_disk_m_16:		;eax=LBA扇区号
			;dx=写入数据的内存地址, cx=读入的扇区数
	mov esi, eax
	mov di, cx

	mov dx, 0x1f2	;设置要读取的扇区数
	mov al, cl	
	out dx, al

	mov eax, esi

	mov dx, 0x1f3	;将LBA地址存入0x1f3 ~ 0x1f6
	out dx, al

	mov cl, 8
	shr eax, cl
	mov dx, 0x1f4
	out dx, al

	shr eax, cl
	mov dx, 0x1f5
	out dx, al

	shr eax, cl
	and al, 0x0f
	or al, 0xe0
	mov dx, 0x1f6
	out dx, al

	mov dx, 0x1f7	;写入读命令
	mov al, 0x20
	out dx, al	

.not_ready:		;检测硬盘状态
	nop	
	in al, dx
	and al, 0x88
	cmp al, 0x08
	jnz .not_ready	

	mov ax, di	;di为要读取的扇区数
	mov dx, 256
	mul dx

	mov cx, ax
	mov dx, 0x1f0	;从0x1f0端口读数据
.go_on_read:
	in ax, dx
	mov [bx], ax
	add bx, 2
	loop .go_on_read
	
	ret

msg:	db "01demo: HELLO MBR"

	times 510-($-$$) db 0
	db 0x55, 0xaa
