
#line 1 "mod/box/memcached.rl"
/*
 * Copyright (C) 2010, 2011 Mail.RU
 * Copyright (C) 2010, 2011 Yuriy Vostrikov
 *
 * Redistribution and use in source and binary forms, with or without
 * modification, are permitted provided that the following conditions
 * are met:
 * 1. Redistributions of source code must retain the above copyright
 *    notice, this list of conditions and the following disclaimer.
 * 2. Redistributions in binary form must reproduce the above copyright
 *    notice, this list of conditions and the following disclaimer in the
 *    documentation and/or other materials provided with the distribution.
 *
 * THIS SOFTWARE IS PROVIDED BY AUTHOR AND CONTRIBUTORS ``AS IS'' AND
 * ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
 * IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
 * ARE DISCLAIMED.  IN NO EVENT SHALL AUTHOR OR CONTRIBUTORS BE LIABLE
 * FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
 * DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS
 * OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION)
 * HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT
 * LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY
 * OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF
 * SUCH DAMAGE.
 */
#include "tarantool.h"
#include "box.h"
#include "fiber.h"
#include "cfg/warning.h"
#include "cfg/tarantool_box_cfg.h"
#include "say.h"
#include "stat.h"
#include "salloc.h"

#define STAT(_)					\
        _(MEMC_GET, 1)				\
        _(MEMC_GET_MISS, 2)			\
	_(MEMC_GET_HIT, 3)			\
	_(MEMC_EXPIRED_KEYS, 4)

ENUM(memcached_stat, STAT);
STRS(memcached_stat, STAT);
int stat_base;

struct index *memcached_index;

/* memcached tuple format:
   <key, meta, data> */

struct meta {
	u32 exptime;
	u32 flags;
	u64 cas;
} __packed__;

static u64
natoq(const u8 *start, const u8 *end)
{
	u64 num = 0;
	while (start < end)
		num = num * 10 + (*start++ - '0');
	return num;
}

static void
store(struct box_txn *txn, void *key, u32 exptime, u32 flags, u32 bytes, u8 *data)
{
	u32 box_flags = BOX_QUIET, cardinality = 4;
	static u64 cas = 42;
	struct meta m;

	struct tbuf *req = tbuf_alloc(fiber->pool);

	tbuf_append(req, &cfg.memcached_namespace, sizeof(u32));
	tbuf_append(req, &box_flags, sizeof(box_flags));
	tbuf_append(req, &cardinality, sizeof(cardinality));

	tbuf_append_field(req, key);

	m.exptime = exptime;
	m.flags = flags;
	m.cas = cas++;
	write_varint32(req, sizeof(m));
	tbuf_append(req, &m, sizeof(m));

	char b[43];
	sprintf(b, " %"PRIu32" %"PRIu32"\r\n", flags, bytes);
	write_varint32(req, strlen(b));
	tbuf_append(req, b, strlen(b));

	write_varint32(req, bytes);
	tbuf_append(req, data, bytes);

	int key_len = load_varint32(&key);
	say_debug("memcached/store key:(%i)'%.*s' exptime:%"PRIu32" flags:%"PRIu32" cas:%"PRIu64,
		  key_len, key_len, (u8 *)key, exptime, flags, cas);
	box_process(txn, INSERT, req); /* FIXME: handle RW/RO */
}

static void
delete(struct box_txn *txn, void *key)
{
	u32 key_len = 1;
	struct tbuf *req = tbuf_alloc(fiber->pool);

	tbuf_append(req, &cfg.memcached_namespace, sizeof(u32));
	tbuf_append(req, &key_len, sizeof(key_len));
	tbuf_append_field(req, key);

	box_process(txn, DELETE, req);
}

static struct box_tuple *
find(void *key)
{
	return memcached_index->find(memcached_index, key);
}

static struct meta *
meta(struct box_tuple *tuple)
{
	void *field = tuple_field(tuple, 1);
	return field + 1;
}

static bool
expired(struct box_tuple *tuple)
{
	struct meta *m = meta(tuple);
	return m->exptime == 0 ? 0 : m->exptime < ev_now();
}

static bool
is_numeric(void *field, u32 value_len)
{
	for (int i = 0; i < value_len; i++)
		if (*((u8 *)field + i) < '0' || '9' < *((u8 *)field + i))
			return false;
	return true;
}

static struct stats {
	u64 total_items;
	u32 curr_connections;
	u32 total_connections;
	u64 cmd_get;
	u64 cmd_set;
	u64 get_hits;
	u64 get_misses;
	u64 evictions;
	u64 bytes_read;
	u64 bytes_written;
} stats;

static void
print_stats()
{
	u64 bytes_used, items;
	struct tbuf *out = tbuf_alloc(fiber->pool);
	slab_stat2(&bytes_used, &items);

	tbuf_printf(out, "STAT pid %"PRIu32"\r\n", (u32)getpid());
	tbuf_printf(out, "STAT uptime %"PRIu32"\r\n", (u32)tarantool_uptime());
	tbuf_printf(out, "STAT time %"PRIu32"\r\n", (u32)ev_now());
	tbuf_printf(out, "STAT version 1.2.5 (tarantool/box)\r\n");
	tbuf_printf(out, "STAT pointer_size %"PRI_SZ"\r\n", sizeof(void *)*8);
	tbuf_printf(out, "STAT curr_items %"PRIu64"\r\n", items);
	tbuf_printf(out, "STAT total_items %"PRIu64"\r\n", stats.total_items);
	tbuf_printf(out, "STAT bytes %"PRIu64"\r\n", bytes_used);
	tbuf_printf(out, "STAT curr_connections %"PRIu32"\r\n", stats.curr_connections);
	tbuf_printf(out, "STAT total_connections %"PRIu32"\r\n", stats.total_connections);
	tbuf_printf(out, "STAT connection_structures %"PRIu32"\r\n", stats.curr_connections); /* lie a bit */
	tbuf_printf(out, "STAT cmd_get %"PRIu64"\r\n", stats.cmd_get);
	tbuf_printf(out, "STAT cmd_set %"PRIu64"\r\n", stats.cmd_set);
	tbuf_printf(out, "STAT get_hits %"PRIu64"\r\n", stats.get_hits);
	tbuf_printf(out, "STAT get_misses %"PRIu64"\r\n", stats.get_misses);
	tbuf_printf(out, "STAT evictions %"PRIu64"\r\n", stats.evictions);
	tbuf_printf(out, "STAT bytes_read %"PRIu64"\r\n", stats.bytes_read);
	tbuf_printf(out, "STAT bytes_written %"PRIu64"\r\n", stats.bytes_written);
	tbuf_printf(out, "STAT limit_maxbytes %"PRIu64"\r\n", (u64)(cfg.slab_alloc_arena * (1 << 30)));
	tbuf_printf(out, "STAT threads 1\r\n");
	tbuf_printf(out, "END\r\n");
	add_iov(out->data, out->len);
}

static void
flush_all(void *data)
{
	uintptr_t delay = (uintptr_t)data;
	fiber_sleep(delay - ev_now());
	khash_t(lstr_ptr_map) *map = memcached_index->idx.str_hash;
	for (khiter_t i = kh_begin(map); i != kh_end(map); i++) {
		if (kh_exist(map, i)) {
			struct box_tuple *tuple = kh_value(map, i);
			meta(tuple)->exptime = 1;
		}
	}
}

#define STORE									\
do {										\
	stats.cmd_set++;							\
	if (bytes > (1<<20)) {							\
		add_iov("SERVER_ERROR object too large for cache\r\n", 41);	\
	} else {								\
		@try {								\
			store(txn, key, exptime, flags, bytes, data);		\
			stats.total_items++;					\
			add_iov("STORED\r\n", 8);				\
		}								\
		@catch (ClientError *e) {					\
			add_iov("SERVER_ERROR ", 13);				\
			add_iov(e->errmsg, strlen(e->errmsg));			\
			add_iov("\r\n", 2);					\
		}								\
	}									\
} while (0)

#include "memcached-grammar.m"

void
memcached_handler(void *_data __attribute__((unused)))
{
	struct box_txn *txn;
	stats.total_connections++;
	stats.curr_connections++;
	int r, p;
	int batch_count;

	for (;;) {
		batch_count = 0;
		if ((r = fiber_bread(fiber->rbuf, 1)) <= 0) {
			say_debug("read returned %i, closing connection", r);
			goto exit;
		}

	dispatch:
		txn = txn_alloc(BOX_QUIET);
		p = memcached_dispatch(txn);
		if (p < 0) {
			say_debug("negative dispatch, closing connection");
			goto exit;
		}

		if (p == 0 && batch_count == 0) /* we havn't successfully parsed any requests */
			continue;

		if (p == 1) {
			batch_count++;
			/* some unparsed commands remain and batch count less than 20 */
			if (fiber->rbuf->len > 0 && batch_count < 20)
				goto dispatch;
		}

		r = fiber_flush_output();
		if (r < 0) {
			say_debug("flush_output failed, closing connection");
			goto exit;
		}

		stats.bytes_written += r;
		fiber_gc();

		if (p == 1 && fiber->rbuf->len > 0) {
			batch_count = 0;
			goto dispatch;
		}
	}
exit:
        fiber_flush_output();
	fiber_sleep(0.01);
	say_debug("exit");
	stats.curr_connections--; /* FIXME: nonlocal exit via exception will leak this counter */
}

void
memcached_init(void)
{
	stat_base = stat_register(memcached_stat_strs, memcached_stat_MAX);
}

void
memcached_expire(void *data __attribute__((unused)))
{
	static khiter_t i;
	khash_t(lstr_ptr_map) *map = memcached_index->idx.str_hash;

	say_info("memcached expire fiber started");
	for (;;) {
		if (i > kh_end(map))
			i = kh_begin(map);

		struct tbuf *keys_to_delete = tbuf_alloc(fiber->pool);
		int expired_keys = 0;

		for (int j = 0; j < cfg.memcached_expire_per_loop; j++, i++) {
			if (i == kh_end(map)) {
				i = kh_begin(map);
				break;
			}

			if (!kh_exist(map, i))
				continue;

			struct box_tuple *tuple = kh_value(map, i);

			if (!expired(tuple))
				continue;

			say_debug("expire tuple %p", tuple);
			tbuf_append_field(keys_to_delete, tuple->data);
		}

		while (keys_to_delete->len > 0) {
			struct box_txn *txn = txn_alloc(BOX_QUIET);
			@try {
				delete(txn, read_field(keys_to_delete));
				expired_keys++;
			}
			@catch (id e) {
				/* The error is already logged. */
			}
		}
		stat_collect(stat_base, MEMC_EXPIRED_KEYS, expired_keys);

		fiber_gc();

		double delay = (double)cfg.memcached_expire_per_loop * cfg.memcached_expire_full_sweep / (map->size + 1);
		if (delay > 1)
			delay = 1;
		fiber_sleep(delay);
	}
}

/*
 * Local Variables:
 * mode: c
 * End:
 * vim: syntax=objc
 */
