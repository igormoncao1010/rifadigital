import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

type CreateSellerBody = {
  name: string;
  email: string;
  password: string;
  phone?: string;
};

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};

Deno.serve(async (request) => {
  if (request.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }

  try {
    const supabaseUrl = Deno.env.get("SUPABASE_URL");
    const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
    const anonKey = Deno.env.get("SUPABASE_ANON_KEY");

    if (!supabaseUrl || !serviceRoleKey || !anonKey) {
      throw new Error("Variaveis do Supabase nao configuradas.");
    }

    const authHeader = request.headers.get("Authorization") || "";
    const userClient = createClient(supabaseUrl, anonKey, {
      global: { headers: { Authorization: authHeader } },
    });
    const adminClient = createClient(supabaseUrl, serviceRoleKey);

    const { data: userData, error: userError } = await userClient.auth.getUser();
    if (userError || !userData.user) {
      throw new Error("Login obrigatorio.");
    }

    const { data: currentSeller, error: sellerError } = await adminClient
      .from("sellers")
      .select("id, role, active")
      .eq("user_id", userData.user.id)
      .single();

    if (sellerError || !currentSeller?.active || !["owner", "admin"].includes(currentSeller.role)) {
      throw new Error("Apenas dono ou admin pode cadastrar vendedores.");
    }

    const body = (await request.json()) as CreateSellerBody;
    if (!body.name || !body.email || !body.password) {
      throw new Error("Nome, email e senha sao obrigatorios.");
    }

    const { data: createdUser, error: createUserError } = await adminClient.auth.admin.createUser({
      email: body.email,
      password: body.password,
      email_confirm: true,
      user_metadata: { name: body.name },
    });

    if (createUserError || !createdUser.user) {
      throw new Error(createUserError?.message || "Nao foi possivel criar o usuario.");
    }

    const { error: insertError } = await adminClient.from("sellers").insert({
      user_id: createdUser.user.id,
      name: body.name,
      email: body.email,
      phone: body.phone || null,
      role: "seller",
      active: true,
    });

    if (insertError) {
      throw new Error(insertError.message);
    }

    return new Response(JSON.stringify({ ok: true }), {
      headers: { ...corsHeaders, "Content-Type": "application/json" },
    });
  } catch (error) {
    const message = error instanceof Error ? error.message : "Erro ao cadastrar vendedor.";
    return new Response(JSON.stringify({ ok: false, error: message }), {
      status: 400,
      headers: { ...corsHeaders, "Content-Type": "application/json" },
    });
  }
});
