defmodule UhtBatch.Factory do
  @moduledoc "测试夹具：构造命令与固定时钟。"

  def batch_id, do: "B-#{:rand.uniform(999_999)}"

  def clock_at(%DateTime{} = dt), do: fn -> dt end

  def clock_fun(times) when is_list(times), do: fn -> nil end

  def base_cmd(batch_id, opts \\ []) do
    t = opts[:at] || ~U[2026-09-10T08:00:00Z]

    %{
      batch_id: batch_id,
      operator_id: opts[:operator] || "op.101",
      occurred_at: t,
      recorded_at: t
    }
  end

  def pretreatment(batch_id, opts \\ []) do
    base_cmd(batch_id, opts)
    |> Map.merge(%{
      record_ref: "PRE-#{batch_id}",
      product_code: "UHT-WHOLE-MILK-3.5"
    })
  end

  def heat_pass(batch_id, opts \\ []) do
    opts = Keyword.put_new(opts, :at, ~U[2026-09-10T08:30:00Z])

    base_cmd(batch_id, opts)
    |> Map.merge(%{record_ref: "UHT-#{batch_id}", line_id: "UHT-LINE-1"})
  end

  def transfer(batch_id, opts \\ []) do
    opts = Keyword.put_new(opts, :at, ~U[2026-09-10T09:05:00Z])

    base_cmd(batch_id, opts)
    |> Map.merge(%{
      tank_id: opts[:tank] || "AT-201",
      previous_batch: opts[:previous_batch],
      heel_present: opts[:heel] || false,
      from: "UHT-LINE-1"
    })
  end

  def filling(batch_id, opts \\ []) do
    opts = Keyword.put_new(opts, :at, ~U[2026-09-10T10:00:00Z])

    base_cmd(batch_id, opts)
    |> Map.merge(%{line_id: "FILL-LINE-7", filler_id: "FILLER-7B"})
  end

  def sample(batch_id, sample_no, lineage, opts \\ []) do
    opts = Keyword.put_new(opts, :at, ~U[2026-09-10T10:20:00Z])

    base_cmd(batch_id, opts)
    |> Map.merge(%{
      sample_no: sample_no,
      sample_type: opts[:type] || :commercial_sterility,
      lineage: lineage,
      record_ref: "SMP-#{sample_no}"
    })
  end

  def pack_roll(batch_id, roll_id, opts \\ []) do
    opts = Keyword.put_new(opts, :at, ~U[2026-09-10T10:05:00Z])

    base_cmd(batch_id, opts)
    |> Map.merge(%{
      roll_id: roll_id,
      material_code: opts[:material] || "LAMI-FILM-TBA-200",
      label_declared: opts[:label] || roll_id,
      label_verified: Keyword.get(opts, :label_verified, true),
      record_ref: "ROLL-#{roll_id}"
    })
  end

  def changeover(batch_id, out_roll, in_roll, splice_seq, opts \\ []) do
    opts =
      opts
      |> Keyword.put_new(:at, ~U[2026-09-10T10:40:00Z])
      |> Keyword.put_new(:seq_before, 12_000)
      |> Keyword.put_new(:seq_after, 12_020)

    base_cmd(batch_id, opts)
    |> Map.merge(%{
      splice_seq: splice_seq,
      out_roll_id: out_roll,
      in_roll_id: in_roll,
      seq_before: opts[:seq_before],
      seq_after: opts[:seq_after],
      equipment_log_ref: opts[:eq_log],
      interface_id: opts[:interface_id],
      record_ref: "SPLICE-#{splice_seq}"
    })
  end
end
